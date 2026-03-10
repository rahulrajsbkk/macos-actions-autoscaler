# GitHub Actions Autoscaling Runners for macOS (Apple Silicon)

A lightweight autoscaler that runs native macOS GitHub Actions runners on Apple Silicon Macs (M2+). Uses the [`actions/scaleset`](https://github.com/actions/scaleset) Go client to poll for job demand and spawn ephemeral runner processes via JIT configs.

**No Kubernetes required.** Designed for Xcode, iOS/macOS builds, and anything that needs real Apple Silicon hardware.

## How It Works

```
Workflow pushed (runs-on: mac-mini-runners)
      ↓
GitHub queues job → matches your scale set
      ↓
Autoscaler (long-polling) receives scaling signal
      ↓
Calls GenerateJitRunnerConfig() → gets one-time JIT token
      ↓
Spawns run.sh with ACTIONS_RUNNER_INPUT_JITCONFIG env var
      ↓
Runner registers, picks up job, executes, self-deregisters
      ↓
Process exits, autoscaler tracks the cleanup
```

Each runner is **ephemeral**: it runs exactly one job, then exits. This ensures a clean environment for every build.

## Scope: Organization vs Single Repo

The `--url` flag controls where the scale set is registered:

| Scope | `--url` value | Runners available to |
|-------|--------------|----------------------|
| **Organization** | `https://github.com/YOUR_ORG` | All repos in the org (subject to runner group policies) |
| **Single repo** | `https://github.com/YOUR_ORG/YOUR_REPO` | Only that specific repository |

**Examples:**

```bash
# Organization-wide — all repos can use runs-on: mac-mini-runners
./actions-scaling --url https://github.com/acme-corp --name mac-mini-runners ...

# Single repo only — only acme-corp/ios-app can use these runners
./actions-scaling --url https://github.com/acme-corp/ios-app --name mac-mini-runners ...
```

When registering at the **org level**, you can further restrict which repos can use the runners via [runner groups](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/managing-access-to-self-hosted-runners-using-groups) in your GitHub org settings.

## Prerequisites

- macOS on Apple Silicon (M2 or newer)
- [Homebrew](https://brew.sh)
- A GitHub organization or repository

## Quick Start

### 1. Create a GitHub App

1. Go to **GitHub → Settings → Developer Settings → GitHub Apps → New GitHub App**
2. Fill in:
   - **Name:** `mac-runner-autoscaler` (or any name)
   - **Homepage URL:** your org URL
   - **Webhook:** uncheck "Active" (not needed)
3. Set **Permissions:**
   - **Repository → Administration:** Read & Write
   - **Organization → Self-hosted runners:** Read & Write
4. Click **Create GitHub App**
5. Note the **Client ID** (shown on the app page, starts with `Iv1.`)
6. Scroll down → **Generate a private key** → save the `.pem` file
7. Click **Install App** → select your organization
8. Note the **Installation ID** from the URL: `https://github.com/settings/installations/INSTALLATION_ID`

### 2. Run Setup

```bash
git clone <this-repo> ~/Works/actions-scaling
cd ~/Works/actions-scaling
cp .env.example .env
nano .env          # fill in your GitHub App credentials
./setup.sh
```

The setup script reads configuration from `.env` (or environment variables) and:
- Installs Go (via Homebrew) if not present
- Downloads the GitHub Actions runner binary (v2.332.0, osx-arm64)
- Builds the autoscaler binary
- Generates a fully configured LaunchDaemon plist from your `.env` values

You can also pass variables inline without a `.env` file:

```bash
GITHUB_URL=https://github.com/acme \
GITHUB_APP_CLIENT_ID=Iv1.abc123 \
GITHUB_APP_INSTALLATION_ID=12345678 \
GITHUB_APP_PRIVATE_KEY_PATH=~/.secrets/github-app.pem \
./setup.sh
```

See `.env.example` for all configurable variables.

### 3. Test Manually

**Organization-wide:**

```bash
./actions-scaling \
  --url https://github.com/YOUR_ORG \
  --name mac-mini-runners \
  --max-runners 4 \
  --runner-dir ~/actions-runner \
  --app-client-id Iv1.YOUR_CLIENT_ID \
  --app-installation-id 12345678 \
  --app-private-key ~/.secrets/github-app.pem
```

**Single repo only:**

```bash
./actions-scaling \
  --url https://github.com/YOUR_ORG/YOUR_REPO \
  --name mac-mini-runners \
  --max-runners 4 \
  --runner-dir ~/actions-runner \
  --app-client-id Iv1.YOUR_CLIENT_ID \
  --app-installation-id 12345678 \
  --app-private-key ~/.secrets/github-app.pem
```

You should see:
```
Starting listener scaleSet=mac-mini-runners scaleSetID=... maxRunners=4
```

### 4. Run as a Daemon (starts on boot, survives restarts)

The setup script installs a **LaunchDaemon** at `/Library/LaunchDaemons/com.github.runner-autoscaler.plist`. Unlike a LaunchAgent, this starts at boot — before any user logs in — and automatically restarts if the process exits.

If you already ran setup with a populated `.env`, the plist is ready to go. Otherwise edit it:

```bash
sudo nano /Library/LaunchDaemons/com.github.runner-autoscaler.plist
```

Load the daemon:

```bash
# Load and start (runs immediately and on every boot)
sudo launchctl bootstrap system /Library/LaunchDaemons/com.github.runner-autoscaler.plist

# Check status
sudo launchctl print system/com.github.runner-autoscaler

# View logs
tail -f /var/log/runner-autoscaler.log
```

Service management commands:

```bash
# Force-start the service now
sudo launchctl kickstart system/com.github.runner-autoscaler

# Stop and unload the service
sudo launchctl bootout system/com.github.runner-autoscaler

# Reload after editing the plist
sudo launchctl bootout system/com.github.runner-autoscaler 2>/dev/null
sudo launchctl bootstrap system /Library/LaunchDaemons/com.github.runner-autoscaler.plist
```

### 5. Target in Workflows

```yaml
# .github/workflows/build.yml
jobs:
  build:
    runs-on: mac-mini-runners  # must match --name
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: xcodebuild -scheme MyApp
```

## CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--url` | (required) | GitHub org URL (`https://github.com/org`) or repo URL (`https://github.com/org/repo`) |
| `--name` | (required) | Scale set name (becomes your `runs-on:` label) |
| `--max-runners` | `4` | Maximum concurrent runner processes |
| `--min-runners` | `0` | Minimum idle runners to keep warm |
| `--labels` | (same as name) | Additional labels for workflow targeting |
| `--runner-group` | `default` | Runner group to join |
| `--runner-dir` | `~/actions-runner` | Path to extracted runner binary |
| `--app-client-id` | | GitHub App Client ID |
| `--app-installation-id` | | GitHub App Installation ID |
| `--app-private-key` | | PEM contents or path to `.pem` file |
| `--token` | | PAT (alternative to GitHub App) |
| `--log-level` | `info` | `debug`, `info`, `warn`, `error` |
| `--log-format` | `text` | `text` or `json` |

## Tuning

| Setting | Recommendation |
|---------|---------------|
| `--max-runners` | Start with CPU cores / 2. For an M2 (8 cores), try 4. |
| `--min-runners` | Set to 1-2 if you want instant job pickup (pre-provisioned). 0 for pure JIT. |
| `--labels` | Add `macos`, `arm64`, `xcode` etc. for fine-grained workflow targeting. |
| `--runner-dir` | Point to a fast SSD path. Avoid network mounts. |

## Architecture

The autoscaler implements the `listener.Scaler` interface from `actions/scaleset`:

- **`HandleDesiredRunnerCount`** — Receives the number of jobs assigned to the scale set. Spawns new `run.sh` processes up to `maxRunners`.
- **`HandleJobStarted`** — Marks a runner as busy (tracks by name → PID).
- **`HandleJobCompleted`** — Waits for process exit, cleans up tracking state.

On shutdown (SIGINT/SIGTERM), all tracked runner processes receive SIGTERM for graceful cleanup.

## Pricing Note

As of March 2026, a $0.002/minute Actions cloud platform charge applies to self-hosted runner usage in private repositories. Factor this into cost planning when running many parallel runners.

## License

MIT
