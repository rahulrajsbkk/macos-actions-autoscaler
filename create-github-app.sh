#!/usr/bin/env bash
#
# Creates a GitHub App with the required permissions for the autoscaler,
# saves the private key, installs it on the org, and updates .env.
#
# Usage:  ./create-github-app.sh
#
# Prerequisites:
#   brew install gh
#   gh auth login
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
CALLBACK_PORT=15782

info()  { printf '\033[0;32m==> %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33mWARNING: %s\033[0m\n' "$*"; }
die()   { printf '\033[0;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

update_env() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
        sed -i '' "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
    else
        echo "${key}=${value}" >> "${ENV_FILE}"
    fi
}

# -----------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------
command -v gh      >/dev/null 2>&1 || die "gh CLI not installed. Run: brew install gh"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
gh auth status >/dev/null 2>&1    || die "Not authenticated. Run: gh auth login"

# -----------------------------------------------------------------
# Determine org/user from .env or prompt
# -----------------------------------------------------------------
OWNER=""
if [ -f "${ENV_FILE}" ]; then
    GITHUB_URL=$(grep '^GITHUB_URL=' "${ENV_FILE}" | cut -d= -f2- | sed 's|https://github.com/||')
    OWNER="${GITHUB_URL%%/*}"
fi

if [ -z "${OWNER}" ]; then
    read -rp "GitHub organization or username: " OWNER
fi
[[ -n "${OWNER}" ]] || die "Organization/username is required"

OWNER_TYPE=$(gh api "/users/${OWNER}" --jq '.type' 2>/dev/null) \
    || die "Cannot find '${OWNER}' on GitHub"

if [[ "${OWNER_TYPE}" == "Organization" ]]; then
    CREATE_URL="https://github.com/organizations/${OWNER}/settings/apps/new"
    info "Organization: ${OWNER}"
else
    CREATE_URL="https://github.com/settings/apps/new"
    info "Personal account: ${OWNER}"
fi

DEFAULT_NAME="${OWNER}-runner-scaler"
DEFAULT_NAME="${DEFAULT_NAME:0:34}"
read -rp "App name [${DEFAULT_NAME}]: " APP_NAME
APP_NAME="${APP_NAME:-${DEFAULT_NAME}}"

# -----------------------------------------------------------------
# Build the app manifest and HTML auto-submit form
# -----------------------------------------------------------------
CALLBACK="http://localhost:${CALLBACK_PORT}/callback"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

python3 - "${APP_NAME}" "${OWNER}" "${CALLBACK}" "${CREATE_URL}" "${WORK}" <<'PYBUILD'
import json, html, sys, os

app_name, owner, callback, create_url, work = sys.argv[1:6]

manifest = json.dumps({
    "name": app_name,
    "url": f"https://github.com/{owner}",
    "hook_attributes": {"active": False},
    "redirect_url": callback,
    "public": False,
    "default_permissions": {
        "administration": "write",
        "organization_self_hosted_runners": "write"
    },
    "default_events": []
})

escaped = html.escape(manifest, quote=True)
page = f"""<!DOCTYPE html>
<html><body>
<p>Redirecting to GitHub&hellip;</p>
<form id="f" method="post" action="{create_url}">
<input type="hidden" name="manifest" value="{escaped}" />
</form>
<script>document.getElementById("f").submit();</script>
</body></html>"""

with open(os.path.join(work, "form.html"), "w") as f:
    f.write(page)
PYBUILD

# -----------------------------------------------------------------
# Start a tiny HTTP server to catch the OAuth redirect
# -----------------------------------------------------------------
python3 - "${CALLBACK_PORT}" "${WORK}/code" <<'PYSERVE' &
import http.server, urllib.parse, sys, os

port, code_path = int(sys.argv[1]), sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        qs = urllib.parse.urlparse(self.path).query
        code = urllib.parse.parse_qs(qs).get("code", [""])[0]
        with open(code_path, "w") as f:
            f.write(code)
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(b"<h2>GitHub App created &#x2014; you can close this tab.</h2>")
        os._exit(0)
    def log_message(self, *_):
        pass

http.server.HTTPServer(("127.0.0.1", port), Handler).handle_request()
PYSERVE
SERVER_PID=$!
sleep 0.5

# -----------------------------------------------------------------
# Step 1: Create the app (browser)
# -----------------------------------------------------------------
info "Opening browser — click 'Create GitHub App' on the page."
open "file://${WORK}/form.html"
info "Waiting for GitHub to redirect back..."
wait "${SERVER_PID}" 2>/dev/null || true

CODE=$(cat "${WORK}/code" 2>/dev/null || echo "")
[[ -n "${CODE}" ]] || die "No authorization code received from GitHub"

# -----------------------------------------------------------------
# Step 2: Exchange the code for app credentials
# -----------------------------------------------------------------
info "Exchanging code for app credentials..."
gh api --method POST "/app-manifests/${CODE}/conversions" > "${WORK}/response.json" 2>/dev/null \
    || die "Code exchange failed (it may have expired — re-run this script)"

python3 - "${WORK}" <<'PYPARSE'
import json, sys, os
work = sys.argv[1]
with open(os.path.join(work, "response.json")) as f:
    d = json.load(f)
for key in ("id", "client_id", "slug", "pem"):
    with open(os.path.join(work, key), "w") as out:
        out.write(str(d[key]))
PYPARSE

APP_ID=$(cat "${WORK}/id")
CLIENT_ID=$(cat "${WORK}/client_id")
APP_SLUG=$(cat "${WORK}/slug")

info "App created successfully!"
echo "    Name:      ${APP_SLUG}"
echo "    App ID:    ${APP_ID}"
echo "    Client ID: ${CLIENT_ID}"

# -----------------------------------------------------------------
# Step 3: Save the private key
# -----------------------------------------------------------------
PEM_DIR="${HOME}/.secrets"
PEM_PATH="${PEM_DIR}/github-app.pem"
mkdir -p "${PEM_DIR}"
chmod 700 "${PEM_DIR}"
cp "${WORK}/pem" "${PEM_PATH}"
chmod 600 "${PEM_PATH}"
info "Private key saved to ${PEM_PATH}"

# -----------------------------------------------------------------
# Step 4: Install the app on the org/account
# -----------------------------------------------------------------
info "Now install the app on '${OWNER}'."
echo "    Opening the installation page in your browser..."
echo "    Select the org/repos and click 'Install'."

if [[ "${OWNER_TYPE}" == "Organization" ]]; then
    ORG_ID=$(gh api "/orgs/${OWNER}" --jq '.id' 2>/dev/null || echo "")
    INSTALL_URL="https://github.com/apps/${APP_SLUG}/installations/new/permissions?target_id=${ORG_ID}"
else
    INSTALL_URL="https://github.com/apps/${APP_SLUG}/installations/new"
fi
open "${INSTALL_URL}"

echo
read -rp "Press Enter after you've installed the app..."

# -----------------------------------------------------------------
# Step 5: Detect the installation ID
# -----------------------------------------------------------------
info "Looking up installation ID..."
INSTALLATION_ID=""

INSTALLATION_ID=$(gh api "/user/installations" --jq \
    ".installations[] | select(.app_slug == \"${APP_SLUG}\") | .id" 2>/dev/null || echo "")

if [[ -z "${INSTALLATION_ID}" && "${OWNER_TYPE}" == "Organization" ]]; then
    INSTALLATION_ID=$(gh api "/orgs/${OWNER}/installations" --jq \
        ".installations[] | select(.app_slug == \"${APP_SLUG}\") | .id" 2>/dev/null || echo "")
fi

if [ -z "${INSTALLATION_ID}" ]; then
    warn "Could not auto-detect the Installation ID."
    echo "    Open: https://github.com/settings/installations"
    echo "    Click your app — the ID is the number at the end of the URL."
    read -rp "Enter Installation ID: " INSTALLATION_ID
    [[ -n "${INSTALLATION_ID}" ]] || die "Installation ID is required"
fi

info "Installation ID: ${INSTALLATION_ID}"

# -----------------------------------------------------------------
# Step 6: Update .env
# -----------------------------------------------------------------
if [ -f "${ENV_FILE}" ]; then
    info "Updating ${ENV_FILE}..."
    update_env "GITHUB_APP_CLIENT_ID" "${CLIENT_ID}"
    update_env "GITHUB_APP_INSTALLATION_ID" "${INSTALLATION_ID}"
    update_env "GITHUB_APP_PRIVATE_KEY_PATH" "${PEM_PATH}"
else
    warn ".env file not found — printing values instead:"
    echo "    GITHUB_APP_CLIENT_ID=${CLIENT_ID}"
    echo "    GITHUB_APP_INSTALLATION_ID=${INSTALLATION_ID}"
    echo "    GITHUB_APP_PRIVATE_KEY_PATH=${PEM_PATH}"
fi

# -----------------------------------------------------------------
# Done
# -----------------------------------------------------------------
echo
info "All done! Your .env now has:"
echo
grep -E '^GITHUB_APP_' "${ENV_FILE}" | sed 's/^/    /'
echo
info "Next: run ./setup.sh to generate the LaunchDaemon plist, then:"
echo "    sudo launchctl bootstrap system /Library/LaunchDaemons/com.github.runner-autoscaler.plist"
