#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# -------------------------------------------------------------------
# 0. Load .env if present (all values can also be set as env vars)
# -------------------------------------------------------------------
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/.env"
    set +a
    echo "==> Loaded configuration from ${SCRIPT_DIR}/.env"
fi

RUNNER_VERSION="${RUNNER_VERSION:-2.332.0}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"
GITHUB_URL="${GITHUB_URL:-https://github.com/YOUR_ORG}"
SCALE_SET_NAME="${SCALE_SET_NAME:-mac-mini-runners}"
MAX_RUNNERS="${MAX_RUNNERS:-4}"
GITHUB_APP_CLIENT_ID="${GITHUB_APP_CLIENT_ID:-}"
GITHUB_APP_INSTALLATION_ID="${GITHUB_APP_INSTALLATION_ID:-}"
GITHUB_APP_PRIVATE_KEY_PATH="${GITHUB_APP_PRIVATE_KEY_PATH:-$HOME/.secrets/github-app.pem}"
RUNNER_USER="${RUNNER_USER:-$(whoami)}"
RUNNER_GROUP="${RUNNER_GROUP:-$(id -gn)}"
RUNNER_HOME="${RUNNER_HOME:-$HOME}"

echo "==> GitHub Actions Autoscaling Runner Setup"
echo "    Runner version: ${RUNNER_VERSION}"
echo "    Runner dir:     ${RUNNER_DIR}"
echo "    Autoscaler dir: ${SCRIPT_DIR}"
echo "    GitHub URL:     ${GITHUB_URL}"
echo "    Scale set:      ${SCALE_SET_NAME}"
echo "    Max runners:    ${MAX_RUNNERS}"
echo "    Run as user:    ${RUNNER_USER}:${RUNNER_GROUP}"
echo

# -------------------------------------------------------------------
# 1. Detect architecture
# -------------------------------------------------------------------
ARCH="$(uname -m)"
case "${ARCH}" in
    arm64) RUNNER_ARCH="arm64" ;;
    x86_64) RUNNER_ARCH="x64" ;;
    *)
        echo "ERROR: Unsupported architecture: ${ARCH}"
        exit 1
        ;;
esac
echo "==> Detected architecture: ${ARCH} (runner arch: ${RUNNER_ARCH})"

# -------------------------------------------------------------------
# 2. Install Homebrew if missing
# -------------------------------------------------------------------
if ! command -v brew &>/dev/null; then
    echo "==> Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# -------------------------------------------------------------------
# 3. Install Go if missing
# -------------------------------------------------------------------
if ! command -v go &>/dev/null; then
    echo "==> Installing Go via Homebrew..."
    brew install go
else
    echo "==> Go already installed: $(go version)"
fi

# -------------------------------------------------------------------
# 4. Download and extract GitHub Actions runner
# -------------------------------------------------------------------
if [ -f "${RUNNER_DIR}/run.sh" ]; then
    echo "==> Runner binary already exists at ${RUNNER_DIR}"
else
    echo "==> Downloading GitHub Actions runner v${RUNNER_VERSION} (osx-${RUNNER_ARCH})..."
    mkdir -p "${RUNNER_DIR}"
    TARBALL="actions-runner-osx-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
    curl -fsSL -o "/tmp/${TARBALL}" \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"
    echo "==> Extracting to ${RUNNER_DIR}..."
    tar xzf "/tmp/${TARBALL}" -C "${RUNNER_DIR}"
    rm -f "/tmp/${TARBALL}"
    echo "==> Runner extracted successfully"
fi

# -------------------------------------------------------------------
# 5. Build the autoscaler
# -------------------------------------------------------------------
echo "==> Building autoscaler..."
cd "${SCRIPT_DIR}"
go build -o actions-scaling .
echo "==> Built: ${SCRIPT_DIR}/actions-scaling"

# -------------------------------------------------------------------
# 6. Generate launchd daemon plist (starts at boot, survives restarts)
# -------------------------------------------------------------------
PLIST_NAME="com.github.runner-autoscaler.plist"
PLIST_DIR="/Library/LaunchDaemons"
PLIST_PATH="${PLIST_DIR}/${PLIST_NAME}"
LOG_DIR="/var/log"
AUTOSCALER_BIN="${SCRIPT_DIR}/actions-scaling"

_needs_credentials=false
if [ -z "${GITHUB_APP_CLIENT_ID}" ] || [ -z "${GITHUB_APP_INSTALLATION_ID}" ]; then
    _needs_credentials=true
fi

if [ -f "${PLIST_PATH}" ]; then
    echo "==> LaunchDaemon plist already exists at ${PLIST_PATH}"
    echo "    To regenerate: delete it first, then re-run setup.sh"
    echo "    To reload:"
    echo "      sudo launchctl bootout system/${PLIST_NAME%.plist} 2>/dev/null; sudo launchctl bootstrap system ${PLIST_PATH}"
else
    sudo tee "${PLIST_PATH}" > /dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.github.runner-autoscaler</string>
    <key>ProgramArguments</key>
    <array>
        <string>${AUTOSCALER_BIN}</string>
        <string>--url</string>
        <string>${GITHUB_URL}</string>
        <string>--name</string>
        <string>${SCALE_SET_NAME}</string>
        <string>--max-runners</string>
        <string>${MAX_RUNNERS}</string>
        <string>--runner-dir</string>
        <string>${RUNNER_DIR}</string>
        <string>--app-client-id</string>
        <string>${GITHUB_APP_CLIENT_ID}</string>
        <string>--app-installation-id</string>
        <string>${GITHUB_APP_INSTALLATION_ID}</string>
        <string>--app-private-key</string>
        <string>${GITHUB_APP_PRIVATE_KEY_PATH}</string>
    </array>
    <key>UserName</key>
    <string>${RUNNER_USER}</string>
    <key>GroupName</key>
    <string>${RUNNER_GROUP}</string>
    <key>WorkingDirectory</key>
    <string>${RUNNER_HOME}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/runner-autoscaler.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/runner-autoscaler-error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>${RUNNER_HOME}</string>
    </dict>
</dict>
</plist>
PLIST
    sudo chown root:wheel "${PLIST_PATH}"
    sudo chmod 644 "${PLIST_PATH}"
    echo "==> Generated LaunchDaemon plist at ${PLIST_PATH}"
    if [ "${_needs_credentials}" = true ]; then
        echo "    WARNING: App credentials are missing. Either:"
        echo "      - Create a .env file (see .env.example) and re-run setup.sh"
        echo "      - Or edit the plist directly: sudo nano ${PLIST_PATH}"
    fi
fi

# -------------------------------------------------------------------
# 7. Migrate from old LaunchAgent if present
# -------------------------------------------------------------------
OLD_PLIST="${HOME}/Library/LaunchAgents/${PLIST_NAME}"
if [ -f "${OLD_PLIST}" ]; then
    echo "==> Found old LaunchAgent at ${OLD_PLIST}"
    launchctl unload "${OLD_PLIST}" 2>/dev/null || true
    rm -f "${OLD_PLIST}"
    echo "    Removed old LaunchAgent (migrated to LaunchDaemon)"
fi

echo
echo "==> Setup complete!"
echo
echo "Next steps:"
echo "  1. Create a GitHub App with these permissions:"
echo "       - Repository > Administration: Read & Write"
echo "       - Organization > Self-hosted runners: Read & Write"
echo "  2. Install the app on your org and note the Client ID + Installation ID"
echo "  3. Configure via .env (recommended):"
echo "       cp .env.example .env"
echo "       \$EDITOR .env          # fill in your credentials"
echo "       ./setup.sh             # re-run to regenerate the plist"
echo "     Or set env vars inline:"
echo "       GITHUB_URL=https://github.com/acme GITHUB_APP_CLIENT_ID=Iv1.xxx ... ./setup.sh"
echo "  4. Load the daemon (starts immediately and on every boot):"
echo "       sudo launchctl bootstrap system ${PLIST_PATH}"
echo "  5. In your workflows, use:  runs-on: ${SCALE_SET_NAME}"
echo
echo "Service management:"
echo "  Start:   sudo launchctl kickstart system/com.github.runner-autoscaler"
echo "  Stop:    sudo launchctl bootout system/com.github.runner-autoscaler"
echo "  Reload:  sudo launchctl bootout system/com.github.runner-autoscaler 2>/dev/null; sudo launchctl bootstrap system ${PLIST_PATH}"
echo "  Status:  sudo launchctl print system/com.github.runner-autoscaler"
echo "  Logs:    tail -f ${LOG_DIR}/runner-autoscaler.log"
