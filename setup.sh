#!/usr/bin/env bash
set -euo pipefail

RUNNER_VERSION="${RUNNER_VERSION:-2.332.0}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> GitHub Actions Autoscaling Runner Setup"
echo "    Runner version: ${RUNNER_VERSION}"
echo "    Runner dir:     ${RUNNER_DIR}"
echo "    Autoscaler dir: ${SCRIPT_DIR}"
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
# 6. Generate launchd plist
# -------------------------------------------------------------------
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/com.github.runner-autoscaler.plist"
LOG_DIR="${HOME}/Library/Logs"

mkdir -p "${PLIST_DIR}" "${LOG_DIR}"

if [ -f "${PLIST_PATH}" ]; then
    echo "==> launchd plist already exists at ${PLIST_PATH}"
    echo "    To reload: launchctl unload '${PLIST_PATH}' && launchctl load '${PLIST_PATH}'"
else
    cat > "${PLIST_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.github.runner-autoscaler</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SCRIPT_DIR}/actions-scaling</string>
        <string>--url</string>
        <string>REPLACE_WITH_GITHUB_ORG_URL</string>
        <string>--name</string>
        <string>REPLACE_WITH_SCALE_SET_NAME</string>
        <string>--max-runners</string>
        <string>4</string>
        <string>--runner-dir</string>
        <string>${RUNNER_DIR}</string>
        <string>--app-client-id</string>
        <string>REPLACE_WITH_APP_CLIENT_ID</string>
        <string>--app-installation-id</string>
        <string>REPLACE_WITH_INSTALLATION_ID</string>
        <string>--app-private-key</string>
        <string>REPLACE_WITH_PATH_TO_PEM</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/runner-autoscaler.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/runner-autoscaler-error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLIST
    echo "==> Generated launchd plist at ${PLIST_PATH}"
    echo "    IMPORTANT: Edit the plist to fill in your GitHub App credentials before loading."
fi

echo
echo "==> Setup complete!"
echo
echo "Next steps:"
echo "  1. Create a GitHub App with these permissions:"
echo "       - Repository > Administration: Read & Write"
echo "       - Organization > Self-hosted runners: Read & Write"
echo "  2. Install the app on your org and note the Client ID + Installation ID"
echo "  3. Test manually (use org URL or repo URL):"
echo "       ${SCRIPT_DIR}/actions-scaling \\"
echo "         --url https://github.com/YOUR_ORG            # org-wide \\"
echo "         --url https://github.com/YOUR_ORG/YOUR_REPO  # single repo \\"
echo "         --name mac-mini-runners \\"
echo "         --max-runners 4 \\"
echo "         --runner-dir ${RUNNER_DIR} \\"
echo "         --app-client-id YOUR_CLIENT_ID \\"
echo "         --app-installation-id YOUR_INSTALLATION_ID \\"
echo "         --app-private-key /path/to/private-key.pem"
echo "  4. Edit the launchd plist with your credentials, then:"
echo "       launchctl load '${PLIST_PATH}'"
echo "  5. In your workflows, use:  runs-on: mac-mini-runners"
