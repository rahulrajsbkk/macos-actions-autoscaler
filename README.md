# GitHub Actions Autoscaling Runners for macOS (Apple Silicon)

A lightweight autoscaler that runs native macOS GitHub Actions runners on Apple Silicon Macs (M2+). Uses the [`actions/scaleset`](https://github.com/actions/scaleset) Go client to poll for job demand and spawn ephemeral runner processes via JIT configs.

**No Kubernetes required.** Designed for Xcode, iOS/macOS builds, and anything that needs real Apple Silicon hardware.

### Why?

GitHub-hosted macOS runners are expensive ($0.08/min) and often run on older Intel hardware. If you already own Apple Silicon Macs — Mac Minis, Mac Studios, or Mac Pros — this autoscaler lets you turn them into a fully managed, auto-scaling CI fleet at a fraction of the cost.

Since runners execute directly on the host, they automatically pick up whatever you've already installed — Xcode, Node.js, Ruby, CocoaPods, Flutter, Android SDK, Homebrew packages, and any other dependencies. No Docker images to maintain, no provisioning scripts to mirror your local toolchain. If it works on your Mac, it works in CI.

Unlike generic self-hosted runner setups that register a single long-lived runner, this project uses **GitHub's official scale-set protocol** to dynamically spin up ephemeral runner processes on demand — the same mechanism that powers Actions Runner Controller (ARC) on Kubernetes, but running natively on macOS without containers or VMs.

### Highlights

- **Zero-to-runner in minutes** — One setup script installs dependencies, builds the binary, and configures a LaunchDaemon
- **Ephemeral by default** — Every job gets a fresh runner process; no state leaks between builds
- **Use your existing toolchain** — Runners inherit everything installed on the host: Xcode, Node.js, Ruby, CocoaPods, Flutter, Homebrew packages — no Docker images to build or sync
- **Native Apple Silicon** — Full access to the GPU, Secure Enclave, Hypervisor.framework, and the iOS Simulator — no Rosetta, no virtualization overhead
- **Scale-set integration** — Uses long-polling (not webhooks) so there's nothing to expose to the internet; works behind NAT and firewalls
- **Runs as a LaunchDaemon** — Starts at boot before any user logs in, survives restarts, auto-recovers on crash
- **Org or repo scoped** — Register runners for your entire GitHub organization or lock them to a single repository
- **Minimal footprint** — Single Go binary (~15 MB), no Docker, no Kubernetes, no external databases

## Use Cases

This autoscaler is ideal for any CI/CD workload that requires macOS or Apple Silicon hardware:

- **iOS / macOS / visionOS app builds** — Xcode builds, archiving, and distribution via `xcodebuild` or Fastlane
- **UI testing** — Run XCUITest, Detox, Maestro, or Appium test suites on the iOS Simulator (backed by real Apple Silicon, not emulation)
- **React Native iOS builds** — Full `npx react-native build-ios` or Expo EAS-compatible local builds with CocoaPods and Xcode toolchains
- **Flutter iOS builds** — `flutter build ios` with native compilation on ARM64; no Rosetta overhead
- **Swift Packages & libraries** — Build and test Swift packages that depend on Apple SDKs or XCTest
- **macOS app signing & notarization** — Code-sign, notarize, and staple `.app` / `.pkg` artifacts with `codesign` and `notarytool`
- **Simulator snapshot testing** — Generate and diff UI snapshots (e.g., with `swift-snapshot-testing` or Percy)
- **Performance & benchmarking** — Consistent hardware means reproducible XCTest performance metrics across runs
- **Cross-platform SDKs** — Build and test Kotlin Multiplatform, .NET MAUI, or Capacitor projects that need an Xcode toolchain for the iOS target
- **Homebrew / macOS CLI tools** — Build, test, and package command-line tools targeting macOS ARM64

Because every runner is **ephemeral** (one job, then exit), each build gets a clean environment — no leftover DerivedData, no stale simulator state, no credential leakage between jobs.

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

The easiest way is the automated script (requires `gh` CLI):

```bash
brew install gh          # if not already installed
gh auth login            # authenticate with GitHub
./create-github-app.sh   # creates app, key, installs, updates .env
```

This will:
- Create a GitHub App with the correct permissions via the manifest flow
- Generate and save the private key to `~/.secrets/github-app.pem`
- Open your browser to install the app on your org
- Auto-detect the Installation ID
- Write `GITHUB_APP_CLIENT_ID`, `GITHUB_APP_INSTALLATION_ID`, and `GITHUB_APP_PRIVATE_KEY_PATH` into `.env`

<details>
<summary>Manual alternative (without gh CLI)</summary>

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
9. Fill in the values in `.env`

</details>

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

Use `runs-on: mac-mini-runners` (or whatever you passed to `--name`) in your workflow files.

**Xcode build & test:**

```yaml
jobs:
  build:
    runs-on: mac-mini-runners
    steps:
      - uses: actions/checkout@v4
      - name: Build & test
        run: |
          xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16' \
            clean build test
```

**XCUITest UI tests:**

```yaml
jobs:
  ui-tests:
    runs-on: mac-mini-runners
    steps:
      - uses: actions/checkout@v4
      - name: Run UI tests
        run: |
          xcodebuild test \
            -scheme MyAppUITests \
            -destination 'platform=iOS Simulator,name=iPhone 16' \
            -resultBundlePath TestResults.xcresult
      - uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: TestResults.xcresult
```

**React Native iOS build:**

```yaml
jobs:
  react-native-ios:
    runs-on: mac-mini-runners
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: cd ios && pod install
      - run: npx react-native build-ios --scheme MyApp --mode Release
```

**Flutter iOS build:**

```yaml
jobs:
  flutter-ios:
    runs-on: mac-mini-runners
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - run: flutter pub get
      - run: flutter build ios --release --no-codesign
```

**Fastlane distribution:**

```yaml
jobs:
  distribute:
    runs-on: mac-mini-runners
    steps:
      - uses: actions/checkout@v4
      - run: bundle install
      - run: bundle exec fastlane beta
        env:
          MATCH_PASSWORD: ${{ secrets.MATCH_PASSWORD }}
          APP_STORE_CONNECT_API_KEY: ${{ secrets.ASC_API_KEY }}
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
