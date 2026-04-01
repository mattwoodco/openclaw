#!/usr/bin/env bash
# Exit immediately on any error, unset variable, or pipe failure
set -Eeuo pipefail

# ============================================================
# OpenClaw in a hardened OrbStack Ubuntu VM (macOS)
# ============================================================
#
# OrbStack lets you run lightweight Linux VMs on macOS.
# This script creates one so OpenClaw runs isolated from your Mac.
#
# What this script does:
#   1. Creates a dedicated OrbStack Ubuntu VM
#   2. Installs Node.js + OpenClaw + Claude Code
#   3. Creates a locked-down service user (no login shell, no sudo)
#   4. Bind-mounts a Mac folder as the agent workspace
#   5. Blocks the VM from accessing the rest of your Mac filesystem
#   6. Configures a firewall (UFW)
#   7. Installs a hardened systemd service
#   8. Injects API keys from .env.local
#   9. Approves the internal CLI device so cron jobs work
#
# Rebuild from scratch:
#   orb delete openclaw
#   ./setup.sh
#
# Security note:
#   OrbStack VMs are integrated with macOS by design.
#   This script reduces that integration significantly, but
#   it is not a perfect isolation boundary.
# ============================================================

# --- Configuration ---
# Get script directory first
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Support config file mode: ./setup.sh config=bubba
CONFIG_NAME="${1:-}"
CONFIG_NAME="${CONFIG_NAME#config=}"
if [[ "${1:-}" == config=* ]] && [[ -f "$SCRIPT_DIR/configs/${CONFIG_NAME}.env" ]]; then
    echo "Loading configuration: $CONFIG_NAME"
    set +u  # Allow unset variables temporarily
    source "$SCRIPT_DIR/configs/${CONFIG_NAME}.env"
    set -u
    echo "  VM Name: $VM_NAME"
    echo "  Port: $OPENCLAW_PORT"
    echo "  Workspace: $WORKSPACE_DIR"
else
    # Traditional environment variable mode
    VM_NAME="${VM_NAME:-openclaw}"
    OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
    MAC_WORKSPACE_DIR="${MAC_WORKSPACE_DIR:-${SCRIPT_DIR}/workspace}"
fi

DISTRO="ubuntu"
SVC_USER="ocagent"
NODE_MAJOR="24"
TIMEOUT_SECONDS="180"
# Default AI model (provider/model format). Override with OPENCLAW_MODEL in .env.local.
DEFAULT_MODEL="anthropic/claude-sonnet-4-20250514"
# Set your Telegram user ID to auto-approve pairing during setup.
# Find yours by messaging @userinfobot on Telegram.
TELEGRAM_USER_ID=""
# Mac folder synced into the VM via bind mount.
# Defaults to a 'workspace/' subdirectory next to this script.

# Set workspace directory (from config or environment)
if [[ -n "${WORKSPACE_DIR:-}" ]]; then
    # Config file specified WORKSPACE_DIR
    MAC_WORKSPACE_DIR="$WORKSPACE_DIR"
else
    # Use environment variable or default
    MAC_WORKSPACE_DIR="${MAC_WORKSPACE_DIR:-${SCRIPT_DIR}/workspace}"
fi

# Convert relative paths to absolute paths (required for OrbStack mounting)
MAC_WORKSPACE_DIR="$(realpath "$MAC_WORKSPACE_DIR")"

# Validate configuration values
[[ "$SVC_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Error: Invalid SVC_USER: ${SVC_USER}" >&2; exit 1; }
[[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] || { echo "Error: Invalid NODE_MAJOR: ${NODE_MAJOR}" >&2; exit 1; }
[[ "$OPENCLAW_PORT" =~ ^[0-9]+$ ]] || { echo "Error: Invalid OPENCLAW_PORT: ${OPENCLAW_PORT}" >&2; exit 1; }
(( OPENCLAW_PORT >= 1 && OPENCLAW_PORT <= 65535 )) || { echo "Error: OPENCLAW_PORT out of range (1-65535): ${OPENCLAW_PORT}" >&2; exit 1; }
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || { echo "Error: Invalid TIMEOUT_SECONDS: ${TIMEOUT_SECONDS}" >&2; exit 1; }

# Path to .env.local with API keys (OPENAI_API_KEY, TELEGRAM_BOT_TOKEN, etc.)
ENV_FILE="${SCRIPT_DIR}/.env.local"

# Strip leading slash to get the path relative to /mnt/mac
MAC_WORKSPACE_PATH="${MAC_WORKSPACE_DIR#/}"

# Reject path traversal in workspace path
[[ "$MAC_WORKSPACE_PATH" == *..* ]] && { echo "Error: MAC_WORKSPACE_DIR must not contain '..': ${MAC_WORKSPACE_DIR}" >&2; exit 1; }

# Allow TELEGRAM_USER_ID and OPENCLAW_MODEL to come from .env.local
if [ -f "$ENV_FILE" ]; then
  [ -z "$TELEGRAM_USER_ID" ] && TELEGRAM_USER_ID="$(grep '^TELEGRAM_USER_ID=' "$ENV_FILE" | cut -d= -f2- || true)"
  ENV_MODEL="$(grep '^OPENCLAW_MODEL=' "$ENV_FILE" | cut -d= -f2- || true)"
  [ -n "$ENV_MODEL" ] && DEFAULT_MODEL="$ENV_MODEL"
fi

# --- Helper functions ---

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required command not found: $1" >&2
    case "$1" in
      orb) echo "  Install OrbStack from https://orbstack.dev" >&2 ;;
      *)   echo "  This is a standard macOS utility — check your PATH" >&2 ;;
    esac
    exit 1
  }
}

# Create a private temp directory (safer than individual temp files)
TMPDIR_PRIVATE="$(mktemp -d -t openclaw-provision.XXXXXX)"
chmod 700 "$TMPDIR_PRIVATE"

cleanup() {
  rm -rf "${TMPDIR_PRIVATE:-}"
}
trap cleanup EXIT
trap 'echo ""; echo "Interrupted. If the VM was partially created, run: orb delete ${VM_NAME}"; cleanup; exit 130' INT TERM

CLOUD_INIT_FILE="${TMPDIR_PRIVATE}/cloud-init.yml"
FIRST_BOOT_FILE="${TMPDIR_PRIVATE}/first-boot.sh"

# --- Pre-flight checks ---

require_cmd orb
require_cmd mktemp
require_cmd awk
require_cmd grep
require_cmd sed

echo "Creating Mac workspace directory: ${MAC_WORKSPACE_DIR}"
mkdir -p "$MAC_WORKSPACE_DIR"

if ! orb status >/dev/null 2>&1; then
  echo "Starting OrbStack..."
  orb start >/dev/null || {
    echo "Error: OrbStack failed to start" >&2
    exit 1
  }
  # Wait for OrbStack to be fully ready
  for i in $(seq 1 15); do
    orb status >/dev/null 2>&1 && break
    sleep 1
  done
  orb status >/dev/null 2>&1 || {
    echo "Error: OrbStack did not become ready within 15 seconds" >&2
    exit 1
  }
fi

# ============================================================
# First-boot script (runs inside the VM as root via cloud-init)
# ============================================================

cat > "$FIRST_BOOT_FILE" <<'BOOT'
#!/usr/bin/env bash
# Exit immediately on any error, unset variable, or pipe failure
set -Eeuo pipefail

# Write a failure marker if anything goes wrong, so the Mac-side
# wait loop can detect failure instead of waiting until timeout.
trap 'install -m 600 /dev/null /tmp/openclaw-boot-status; echo "FAILED" > /tmp/openclaw-boot-status' ERR

SVC_USER="{{SVC_USER}}"
NODE_MAJOR="{{NODE_MAJOR}}"
OPENCLAW_PORT="{{OPENCLAW_PORT}}"
MAC_WORKSPACE_PATH="{{MAC_WORKSPACE_PATH}}"

# Suppress apt interactive prompts during package install
export DEBIAN_FRONTEND=noninteractive

echo "[1/9] Installing base packages..."
apt-get update -qq
apt-get install -y -qq \
  ca-certificates \
  curl \
  git \
  jq \
  ufw >/dev/null

# OrbStack symlinks /etc/resolv.conf to /opt/orbstack-guest/etc/resolv.conf.
# Snap packages run in a mount namespace that can't follow this symlink,
# so DNS fails inside snaps. Replace the symlink with a regular file.
if [ -L /etc/resolv.conf ]; then
  RESOLV_CONTENT="$(cat /etc/resolv.conf)"
  rm -f /etc/resolv.conf
  printf '%s\n' "$RESOLV_CONTENT" > /etc/resolv.conf
  chmod 644 /etc/resolv.conf
fi

# Add GitHub CLI repo and install gh
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update -qq
apt-get install -y -qq gh >/dev/null

echo "[2/9] Installing Node.js ${NODE_MAJOR}..."
CURRENT_NODE_MAJOR=""
if command -v node >/dev/null 2>&1; then
  CURRENT_NODE_MAJOR="$(node --version | sed 's/^v//' | cut -d. -f1)"
fi
if [ "$CURRENT_NODE_MAJOR" != "$NODE_MAJOR" ]; then
  # Enforce HTTPS and TLS 1.2+ for the setup script
  curl --proto '=https' --tlsv1.2 -fsSL \
    "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
echo "  Node.js $(node --version) installed"

echo "[3/9] Creating service user..."
if ! id "$SVC_USER" >/dev/null 2>&1; then
  # nologin shell: this user runs services only, not interactive sessions
  useradd -m -s /usr/sbin/nologin "$SVC_USER"
  passwd -l "$SVC_USER"
  chmod 750 "/home/${SVC_USER}"
fi
# Ensure no sudo/admin group membership (ignore errors if not in group)
rm -f "/etc/sudoers.d/${SVC_USER}" 2>/dev/null || true
deluser "$SVC_USER" sudo 2>/dev/null || true
deluser "$SVC_USER" admin 2>/dev/null || true

echo "[4/9] Preparing workspace mount point..."
# OrbStack mounts your Mac at /mnt/mac by default (VirtioFS).
# The actual bind-mount happens post-boot from the Mac side, because
# VirtioFS is not available during cloud-init first boot.
mkdir -p /workspace/vm-openclaw
chown "${SVC_USER}:${SVC_USER}" /workspace/vm-openclaw

# Block cross-VM mount point
mkdir -p /mnt/machines
mount -t tmpfs -o size=0,ro tmpfs /mnt/machines 2>/dev/null || chmod 000 /mnt/machines 2>/dev/null || true

echo "[5/9] Installing mac-isolation service for reboot persistence..."
# On subsequent boots (not first boot), VirtioFS IS available before
# multi-user.target, so the systemd service handles the bind-mount.
cat > /etc/systemd/system/mac-isolation.service <<MSVC
[Unit]
Description=Bind-mount Mac workspace and block remaining Mac filesystem access
After=local-fs.target
Before=openclaw.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'mkdir -p /workspace/vm-openclaw && mount --bind "/mnt/mac/${MAC_WORKSPACE_PATH}" /workspace/vm-openclaw && mount -t tmpfs -o size=0,ro tmpfs /mnt/mac'
ExecStop=/bin/bash -c 'umount /workspace/vm-openclaw 2>/dev/null || true; umount /mnt/mac 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
MSVC

systemctl daemon-reload
systemctl enable mac-isolation.service >/dev/null

echo "[6/9] Configuring firewall..."
# WARNING: This resets all UFW rules. Safe for a fresh VM,
# but destructive if you've added custom rules manually.
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default deny outgoing >/dev/null
ufw allow out to any port 443 proto tcp >/dev/null   # HTTPS (npm, API calls)
ufw allow out to any port 80 proto tcp >/dev/null    # HTTP (apt repos)
ufw allow out to any port 53 proto udp >/dev/null    # DNS
ufw allow out to any port 53 proto tcp >/dev/null    # DNS over TCP
# Allow OpenClaw port on loopback + OrbStack bridge only
ufw allow in on lo to any port "$OPENCLAW_PORT" proto tcp >/dev/null
ufw allow in on eth0 to any port "$OPENCLAW_PORT" proto tcp >/dev/null
ufw --force enable >/dev/null

echo "[7/9] Installing OpenClaw + tools..."
# Install globally as root so the binaries are in the system PATH.
npm install -g openclaw@latest @anthropic-ai/claude-code@latest agent-browser@latest @googleworkspace/cli@latest 2>&1 | tee /var/log/openclaw-npm-install.log
tail -1 /var/log/openclaw-npm-install.log

# Install Playwright's Chromium for agent-browser.
# The Ubuntu snap chromium has DNS issues in OrbStack VMs because the snap's
# mount namespace can't always reach OrbStack's DNS resolver. Playwright
# bundles a standalone Chromium binary that avoids snap confinement entirely.
echo "  Installing Playwright Chromium (non-snap)..."
npm install -g playwright@latest 2>&1 | tail -1
npx playwright install chromium 2>&1 | tail -1 || true
npx playwright install-deps chromium 2>&1 | tail -1 || true

# Copy Playwright's headless_shell to a stable system path.
# headless_shell is optimized for headless automation — no crashpad issues,
# smaller footprint, and all CDP features agent-browser needs.
PW_HEADLESS="$(find /root/.cache/ms-playwright -name 'headless_shell' -print -quit 2>/dev/null)"
if [ -n "$PW_HEADLESS" ]; then
  PW_HEADLESS_DIR="$(dirname "$PW_HEADLESS")"
  mkdir -p /opt/chromium-headless
  cp -a "$PW_HEADLESS_DIR"/* /opt/chromium-headless/
  chmod -R 755 /opt/chromium-headless
  echo "  Playwright headless_shell installed to /opt/chromium-headless/"
else
  echo "  Warning: Playwright headless_shell not found. agent-browser may not work." >&2
fi

# Configure npm and create config directories for the service user
su -s /bin/bash - "$SVC_USER" -c "
  set -Eeuo pipefail
  mkdir -p ~/.openclaw
  mkdir -p ~/.claude
  mkdir -p ~/.npm-global
  npm config set prefix ~/.npm-global
  echo 'export PATH=\$HOME/.npm-global/bin:\$HOME/.local/bin:\$PATH' >> ~/.bashrc
"

echo "[8/9] Writing OpenClaw config..."
cat > "/home/${SVC_USER}/.openclaw/openclaw.json" <<EOF
{
  "gateway": {
    "mode": "local",
    "port": ${OPENCLAW_PORT},
    "bind": "0.0.0.0",
    "trustedProxies": ["10.0.0.0/8", "127.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "::1"],
    "controlUi": {
      "allowedOrigins": [
        "http://localhost:${OPENCLAW_PORT}",
        "http://127.0.0.1:${OPENCLAW_PORT}"
      ]
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/workspace/vm-openclaw",
      "model": "{{DEFAULT_MODEL}}",
      "sandbox": {
        "mode": "off"
      }
    }
  }
}
EOF

chown -R "${SVC_USER}:${SVC_USER}" "/home/${SVC_USER}/.openclaw"
chmod 700 "/home/${SVC_USER}/.openclaw"
chmod 600 "/home/${SVC_USER}/.openclaw/openclaw.json"

# Disable built-in browser — agent uses agent-browser skill instead
# Disable macOS-only and hardware-dependent skills that can't work in a VM
su -s /bin/bash - "$SVC_USER" -c "
  openclaw config set browser.enabled false 2>/dev/null || true

  # Complete approval bypass configuration
  openclaw config set approvals.exec.enabled false 2>/dev/null || true
  openclaw config set gateway.mode local 2>/dev/null || true

  # Enable exec approvals on Telegram so commands can run from chat
  openclaw config set channels.telegram.execApprovals --strict-json '{\"enabled\":true}' 2>/dev/null || true

  for skill in apple-notes apple-reminders bear-notes blogwatcher bluebubbles blucli camsnap eightctl gemini gog goplaces himalaya imsg node-connect obsidian openai-whisper openai-whisper-api openhue ordercli peekaboo sag sherpa-onnx-tts songsee sonoscli spotify-player summarize things-mac voice-call wacli; do
    openclaw config set skills.entries.\${skill}.enabled false 2>/dev/null || true
  done

  # Auto-approve all commands to eliminate approval prompts
  sleep 2  # Give gateway time to start

  # Comprehensive allowlist patterns for complete bypass
  openclaw approvals allowlist add '*' 2>/dev/null || true
  openclaw approvals allowlist add 'gws*' 2>/dev/null || true
  openclaw approvals allowlist add 'github*' 2>/dev/null || true
  openclaw approvals allowlist add 'gh*' 2>/dev/null || true
  openclaw approvals allowlist add 'git*' 2>/dev/null || true
  openclaw approvals allowlist add 'npm*' 2>/dev/null || true
  openclaw approvals allowlist add 'node*' 2>/dev/null || true
  openclaw approvals allowlist add 'curl*' 2>/dev/null || true
  openclaw approvals allowlist add 'wget*' 2>/dev/null || true
  openclaw approvals allowlist add 'bash*' 2>/dev/null || true
  openclaw approvals allowlist add 'sh*' 2>/dev/null || true

  # Verify approval configuration
  echo 'Approval bypass configuration applied:'
  openclaw config get approvals.exec.enabled 2>/dev/null || echo '  approvals.exec.enabled: not set'
  openclaw config get gateway.mode 2>/dev/null || echo '  gateway.mode: not set'
  openclaw approvals allowlist list 2>/dev/null || echo '  allowlist: not accessible'
"

echo "[9/10] Installing headless Chrome service..."
mkdir -p "/home/${SVC_USER}/.chrome-data"
chown "${SVC_USER}:${SVC_USER}" "/home/${SVC_USER}/.chrome-data"

# Use Playwright's headless_shell if available, fall back to system chromium.
if [ -x /opt/chromium-headless/headless_shell ]; then
  CHROME_BIN="/opt/chromium-headless/headless_shell"
else
  CHROME_BIN="$(which chromium-browser 2>/dev/null || echo '/usr/bin/chromium-browser')"
fi

cat > /etc/systemd/system/headless-chrome.service <<EOF
[Unit]
Description=Headless Chrome for agent-browser
After=network-online.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
Environment=DBUS_SESSION_BUS_ADDRESS=/dev/null
ExecStart=${CHROME_BIN} --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-software-rasterizer --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 --user-data-dir=/home/${SVC_USER}/.chrome-data
Restart=on-failure
RestartSec=3
MemoryMax=2G
CPUQuota=150%

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable headless-chrome.service >/dev/null

# Configure agent-browser to use Playwright's headless_shell instead of snap chromium.
# This avoids DNS resolution failures caused by snap mount namespace isolation.
mkdir -p "/home/${SVC_USER}/.agent-browser"
cat > "/home/${SVC_USER}/.agent-browser/config.json" <<EOF
{
  "executablePath": "${CHROME_BIN}",
  "args": "--no-sandbox,--disable-dev-shm-usage,--disable-software-rasterizer"
}
EOF
chown -R "${SVC_USER}:${SVC_USER}" "/home/${SVC_USER}/.agent-browser"

echo "[10/10] Installing systemd service..."
OPENCLAW_BIN="$(command -v openclaw 2>/dev/null || true)"
if [ -z "$OPENCLAW_BIN" ]; then
  for candidate in /usr/local/bin/openclaw /usr/bin/openclaw; do
    if [ -x "$candidate" ]; then
      OPENCLAW_BIN="$candidate"
      break
    fi
  done
fi
if [ -z "$OPENCLAW_BIN" ]; then
  echo "Error: openclaw binary not found after install." >&2
  echo "  Check /var/log/openclaw-npm-install.log for details." >&2
  exit 1
fi

cat > /etc/systemd/system/openclaw.service <<EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target mac-isolation.service
Wants=network-online.target mac-isolation.service

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
WorkingDirectory=/workspace/vm-openclaw
Environment=HOME=/home/${SVC_USER}
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/lib/nodejs/bin
# Prevent inheriting the host's SSH agent socket
Environment=SSH_AUTH_SOCK=
EnvironmentFile=-/home/${SVC_USER}/.openclaw/.anthropic-env
ExecStart=${OPENCLAW_BIN} gateway run
Restart=on-failure
RestartSec=5

# --- Security hardening ---
# Restrict what this service process is allowed to do at the OS level.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
# Only allow writes to the directories openclaw actually needs
ReadWritePaths=/workspace/vm-openclaw /home/${SVC_USER}/.openclaw /home/${SVC_USER}/.claude /home/${SVC_USER}/.chrome-data /tmp/openclaw
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
PrivateDevices=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictNamespaces=true
ProtectKernelLogs=true
ProtectClock=true
ProtectHostname=true
SystemCallArchitectures=native
LimitNPROC=1024
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openclaw.service >/dev/null

echo "Base install complete."
echo
echo "Machine: openclaw"
echo "User:    ${SVC_USER}"
echo "Port:    ${OPENCLAW_PORT}"

# Clean up the provisioning script (it has served its purpose)
rm -f /root/first-boot-openclaw.sh

# Write success marker for the Mac-side wait loop
install -m 600 /dev/null /tmp/openclaw-boot-status
echo "OK" > /tmp/openclaw-boot-status
BOOT

# Replace template variables (using | delimiter to avoid issues with / in values)
sed -i '' \
  -e "s|{{SVC_USER}}|${SVC_USER}|g" \
  -e "s|{{NODE_MAJOR}}|${NODE_MAJOR}|g" \
  -e "s|{{OPENCLAW_PORT}}|${OPENCLAW_PORT}|g" \
  -e "s|{{MAC_WORKSPACE_PATH}}|${MAC_WORKSPACE_PATH}|g" \
  -e "s|{{DEFAULT_MODEL}}|${DEFAULT_MODEL}|g" \
  "$FIRST_BOOT_FILE"

# ============================================================
# Build cloud-init config
# cloud-init is a standard tool that runs setup scripts on
# the first boot of a new VM.
# ============================================================

INDENTED_BOOT="$(sed 's/^/      /' "$FIRST_BOOT_FILE"; echo '.')"
INDENTED_BOOT="${INDENTED_BOOT%.}"

cat > "$CLOUD_INIT_FILE" <<EOF
#cloud-config
package_update: false
package_upgrade: false

write_files:
  - path: /root/first-boot-openclaw.sh
    permissions: '0700'
    content: |
${INDENTED_BOOT}
# cloud-init will run this script on first boot
runcmd:
  - [ bash, /root/first-boot-openclaw.sh ]
EOF

# ============================================================
# Create and provision the VM
# ============================================================

echo "Creating OrbStack machine: ${VM_NAME}"
if ! orb create "$DISTRO" "$VM_NAME" -c "$CLOUD_INIT_FILE" 2>&1; then
  if orb list | awk '{print $1}' | grep -qx "$VM_NAME"; then
    echo "Machine already exists: ${VM_NAME}"
    echo "  To rebuild: orb delete ${VM_NAME} && ./setup.sh"
  else
    echo "Error: Failed to create VM. Check disk space and OrbStack status." >&2
  fi
  exit 1
fi

echo "Waiting for first boot to finish (this takes 1-3 minutes)..."
orb -m "$VM_NAME" -u root bash -lc "
  set -e
  TIMEOUT=${TIMEOUT_SECONDS}
  ELAPSED=0
  while true; do
    # Check for failure marker (fast exit on error)
    if [ -f /tmp/openclaw-boot-status ] && grep -q FAILED /tmp/openclaw-boot-status 2>/dev/null; then
      echo '' >&2
      echo 'Error: first-boot script failed inside the VM.' >&2
      echo 'Check: orb -m ${VM_NAME} -u root cat /var/log/cloud-init-output.log' >&2
      exit 1
    fi
    # Check for success marker
    if [ -f /tmp/openclaw-boot-status ] && grep -q OK /tmp/openclaw-boot-status 2>/dev/null; then
      break
    fi
    printf '.' >&2
    sleep 2
    ELAPSED=\$((ELAPSED + 2))
    if [ \"\$ELAPSED\" -ge \"\$TIMEOUT\" ]; then
      echo '' >&2
      echo \"Error: first boot timed out after \${TIMEOUT}s\" >&2
      echo \"Check: orb -m ${VM_NAME} -u root cat /var/log/cloud-init-output.log\" >&2
      exit 1
    fi
  done
  echo '' >&2
"

# ============================================================
# Set up workspace bind-mount (VirtioFS is now available)
# ============================================================

echo
echo "Mounting Mac workspace into VM..."
orb -m "$VM_NAME" -u root bash -c "
  mkdir -p /workspace/vm-openclaw
  mount --bind '/mnt/mac/${MAC_WORKSPACE_PATH}' /workspace/vm-openclaw
  chown ${SVC_USER}:${SVC_USER} /workspace/vm-openclaw
  # Block the rest of /mnt/mac
  mount -t tmpfs -o size=0,ro tmpfs /mnt/mac
  # Mark mac-isolation as succeeded so openclaw.service starts cleanly
  systemctl reset-failed mac-isolation.service 2>/dev/null || true
"
echo "  Workspace mounted: /workspace/vm-openclaw ↔ ${MAC_WORKSPACE_DIR}"

echo "Installing skills..."
SKILLS_SRC="$(cd "$(dirname "$0")" && pwd)/skills"
REQUIRED_SKILLS="openclaw-agent-browser-clawdbot gws-workspace github"
orb -m "$VM_NAME" -u root bash -c "mkdir -p /workspace/vm-openclaw/skills"

for skill_name in $REQUIRED_SKILLS; do
  # Local copy first (instant, no network)
  if [ -d "$SKILLS_SRC/$skill_name" ]; then
    echo "  $skill_name (bundled)"
    orb -m "$VM_NAME" -u root bash -c "rm -rf /workspace/vm-openclaw/skills/$skill_name"
    cp -r "$SKILLS_SRC/$skill_name" "$MAC_WORKSPACE_DIR/skills/$skill_name"
    orb -m "$VM_NAME" -u root chown -R "${SVC_USER}:${SVC_USER}" "/workspace/vm-openclaw/skills/$skill_name"
  else
    # Fallback to ClawHub with retry
    echo "  $skill_name (ClawHub)"
    for attempt in 1 2 3; do
      if orb -m "$VM_NAME" -u root su -s /bin/bash "$SVC_USER" -c \
           "openclaw skills install $skill_name 2>&1"; then
        break
      fi
      echo "    retry $((attempt+1))/3..."
      sleep 5
    done
  fi
done

# ============================================================
# Inject API keys from .env.local (BEFORE starting the service)
# ============================================================

OPENAI_KEY=""
TELEGRAM_TOKEN=""
ANTHROPIC_KEY=""

if [ -f "$ENV_FILE" ]; then
  echo
  echo "Found .env.local — injecting API keys..."

  OPENAI_KEY="$(grep '^OPENAI_API_KEY=' "$ENV_FILE" | cut -d= -f2- || true)"
  # Use config-specific TELEGRAM_BOT_TOKEN if set, otherwise fall back to .env.local
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    TELEGRAM_TOKEN="$(grep '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2- || true)"
  else
    TELEGRAM_TOKEN="$TELEGRAM_BOT_TOKEN"
    echo "  Using config-specific TELEGRAM_BOT_TOKEN"
  fi
  ANTHROPIC_KEY="$(grep '^ANTHROPIC_API_KEY=' "$ENV_FILE" | cut -d= -f2- || true)"
  GITHUB_TOKEN="$(grep '^GITHUB_TOKEN=' "$ENV_FILE" | cut -d= -f2- || true)"

  # At least one AI provider key is required
  if [ -z "$ANTHROPIC_KEY" ] && [ -z "$OPENAI_KEY" ]; then
    echo "Error: No AI provider key found in ${ENV_FILE}." >&2
    echo "  Set at least one of ANTHROPIC_API_KEY or OPENAI_API_KEY." >&2
    exit 1
  fi

  echo "  Model: ${DEFAULT_MODEL}"

  # Helper: set a config path to a JSON object via a temp file inside the VM.
  # This avoids shell quoting issues with nested JSON.
  oc_set_object() {
    local config_path="$1"
    local json_value="$2"
    printf '%s' "$json_value" | orb -m "$VM_NAME" -u root bash -c "
      OC_TMP=/home/$SVC_USER/.openclaw/oc-cfg.json
      trap 'rm -f \$OC_TMP' EXIT
      umask 077
      cat > \$OC_TMP
      chown $SVC_USER:$SVC_USER \$OC_TMP
      su -s /bin/bash $SVC_USER -c \"openclaw config set '$config_path' --strict-json \\\"\\\$(cat \$OC_TMP)\\\"\"
    " 2>&1
  }

  if [ -n "$ANTHROPIC_KEY" ]; then
    echo "  Configuring Anthropic provider..."
    json_value=$(jq -n --arg key "$ANTHROPIC_KEY" '{baseUrl:"https://api.anthropic.com",apiKey:$key,models:[{id:"claude-sonnet-4-20250514",name:"Claude Sonnet 4"},{id:"claude-haiku-4-5-20251001",name:"Claude Haiku 4.5"}]}')
    oc_set_object "models.providers.anthropic" "$json_value"
    # Also set for Claude Code (systemd EnvironmentFile)
    printf '%s' "$ANTHROPIC_KEY" | orb -m "$VM_NAME" -u root bash -c "
      ENV_PATH=/home/$SVC_USER/.openclaw/.anthropic-env
      TMPF=\$(mktemp \$ENV_PATH.XXXXXX)
      printf 'ANTHROPIC_API_KEY=%s\n' \"\$(cat)\" > \$TMPF
      chmod 600 \$TMPF
      chown $SVC_USER:$SVC_USER \$TMPF
      mv \$TMPF \$ENV_PATH
    "
    echo "  Anthropic: configured"
  fi

  if [ -n "$OPENAI_KEY" ]; then
    echo "  Configuring OpenAI provider..."
    json_value=$(jq -n --arg key "$OPENAI_KEY" '{baseUrl:"https://api.openai.com/v1",apiKey:$key,models:[{id:"gpt-4o",name:"GPT-4o"},{id:"gpt-4o-mini",name:"GPT-4o Mini"},{id:"o3-mini",name:"o3-mini"}]}')
    oc_set_object "models.providers.openai" "$json_value"
    echo "  OpenAI: configured"
  fi

  if [ -n "$TELEGRAM_TOKEN" ]; then
    echo "  Configuring Telegram bot..."
    if [ -n "${TELEGRAM_USER_ID:-}" ]; then
      json_value=$(jq -n --arg token "$TELEGRAM_TOKEN" --arg uid "$TELEGRAM_USER_ID" \
        '{botToken:$token,enabled:true,dmPolicy:"allowlist",allowFrom:[$uid]}')
      echo "  Telegram: configured (user ${TELEGRAM_USER_ID} pre-authorized)"
    else
      json_value=$(jq -n --arg token "$TELEGRAM_TOKEN" '{botToken:$token,enabled:true}')
      echo "  Telegram: configured (pairing required — set TELEGRAM_USER_ID in .env.local to skip)"
    fi
    oc_set_object "channels.telegram" "$json_value"
  fi

  if [ -n "$GITHUB_TOKEN" ]; then
    echo "  Configuring GitHub CLI..."
    printf '%s' "$GITHUB_TOKEN" | orb -m "$VM_NAME" -u root bash -c "
      GH_VAL=\"\$(cat)\"
      # Add to systemd env file (used by openclaw.service and agent sessions)
      printf 'GH_TOKEN=%s\n' \"\$GH_VAL\" >> /home/$SVC_USER/.openclaw/.anthropic-env
    "
    echo "  GitHub: configured"
  fi

  # Add approval bypass environment variables for persistence
  echo "  Configuring approval bypass environment..."
  orb -m "$VM_NAME" -u root bash -c "
    ENV_PATH=/home/$SVC_USER/.openclaw/.anthropic-env
    # Ensure the environment file exists
    touch \$ENV_PATH
    chown $SVC_USER:$SVC_USER \$ENV_PATH
    chmod 600 \$ENV_PATH
    # Add approval bypass environment variables
    echo 'OPENCLAW_APPROVALS_EXEC_ENABLED=false' >> \$ENV_PATH
    echo 'OPENCLAW_GATEWAY_MODE=local' >> \$ENV_PATH
    echo 'OPENCLAW_AUTO_APPROVE=true' >> \$ENV_PATH
  "
  echo "  Approval bypass environment: configured"

  # Google Workspace: copy client_secret.json if found next to setup.sh
  GWS_SECRET_FILE="$(find "$SCRIPT_DIR" -maxdepth 1 -name 'client_secret*.json' -print -quit 2>/dev/null)"
  if [ -n "$GWS_SECRET_FILE" ]; then
    echo "  Configuring Google Workspace CLI credentials..."
    cat "$GWS_SECRET_FILE" | orb -m "$VM_NAME" -u root bash -c "
      GWS_DIR=/home/$SVC_USER/.config/gws
      mkdir -p \$GWS_DIR
      cat > \$GWS_DIR/client_secret.json
      chmod 600 \$GWS_DIR/client_secret.json
      chown -R $SVC_USER:$SVC_USER \$GWS_DIR
    "
    echo "  Google Workspace: configured"
  fi
else
  echo
  echo "No .env.local found at ${ENV_FILE} — skipping API key injection."
  echo "  You can set keys later with:"
  echo "  orb -m ${VM_NAME} -u root su -s /bin/bash ${SVC_USER} -c 'openclaw onboard'"
fi

# Clear secrets from shell environment
OPENAI_CONFIGURED="${OPENAI_KEY:+1}"
TELEGRAM_CONFIGURED="${TELEGRAM_TOKEN:+1}"
ANTHROPIC_CONFIGURED="${ANTHROPIC_KEY:+1}"
GITHUB_CONFIGURED="${GITHUB_TOKEN:+1}"
GWS_CONFIGURED="${GWS_SECRET_FILE:+1}"
unset OPENAI_KEY TELEGRAM_TOKEN ANTHROPIC_KEY GITHUB_TOKEN json_value

# ============================================================
# Start the service
# ============================================================

echo
echo "Fixing directory permissions for macOS file access..."
orb -m "$VM_NAME" -u root chmod 750 "/home/${SVC_USER}"

echo "Starting services..."
orb -m "$VM_NAME" -u root systemctl start headless-chrome
orb -m "$VM_NAME" -u root systemctl start openclaw

# Wait for the gateway to be ready (up to 60s)
echo "Waiting for gateway to become ready..."
READY=0
for i in $(seq 1 30); do
  if curl -s -o /dev/null -w '' "http://localhost:${OPENCLAW_PORT}" 2>/dev/null; then
    READY=1
    break
  fi
  printf '.' >&2
  sleep 2
done
echo '' >&2

if [ "$READY" -ne 1 ]; then
  echo "Warning: Gateway not responding on port ${OPENCLAW_PORT} yet." >&2
  echo "  The service may still be starting. Check:" >&2
  echo "  orb -m ${VM_NAME} -u root systemctl status openclaw" >&2
fi

# ============================================================
# Unlock cron + CLI: approve the gateway-client device
# ============================================================
#
# WHY THIS IS NEEDED:
#   OpenClaw's cron scheduler and CLI tools connect to the gateway
#   via WebSocket. On first connect, the device only gets "read"
#   permission. Cron jobs need "admin" permission to create/run jobs.
#   Without this step, every cron command fails with "pairing required".
#
#   The trustedProxies config (above) helps the gateway recognize
#   internal VM traffic, but the first-time device still needs an
#   explicit approval to get full scopes. This block handles that.
#
if [ "$READY" -eq 1 ]; then
  echo "Unlocking cron + CLI (device approval)..."

  # Poke the gateway so the CLI device registers itself
  orb -m "$VM_NAME" -u root su -s /bin/bash "$SVC_USER" -c \
    "openclaw gateway health >/dev/null 2>&1 || true"
  sleep 2

  # Approve any pending device request
  PENDING_ID="$(orb -m "$VM_NAME" -u root bash -c \
    "cat /home/${SVC_USER}/.openclaw/devices/pending.json 2>/dev/null" \
    | jq -r 'keys[0] // empty' 2>/dev/null || true)"

  if [ -n "$PENDING_ID" ]; then
    orb -m "$VM_NAME" -u root su -s /bin/bash "$SVC_USER" -c \
      "openclaw devices approve ${PENDING_ID}" 2>&1 || true
    echo "  Device approved"
  else
    echo "  Device already approved"
  fi

  # Confirm cron is working
  if orb -m "$VM_NAME" -u root su -s /bin/bash "$SVC_USER" -c \
    "openclaw cron status --json 2>/dev/null" | jq -e '.enabled' >/dev/null 2>&1; then
    echo "  Cron: OK"
  else
    echo "  Warning: Cron not responding. Run: openclaw doctor --fix" >&2
  fi

  # Reinforce approval bypass configuration now that gateway is fully running
  echo "  Reinforcing approval bypass configuration..."
  orb -m "$VM_NAME" -u root su -s /bin/bash "$SVC_USER" -c "
    # Ensure exec approvals are completely disabled
    openclaw config set approvals.exec.enabled false 2>/dev/null || true
    openclaw config set gateway.mode local 2>/dev/null || true

    # Reinforce comprehensive allowlist patterns
    openclaw approvals allowlist clear 2>/dev/null || true
    openclaw approvals allowlist add '*' 2>/dev/null || true
    openclaw approvals allowlist add 'gws*' 2>/dev/null || true
    openclaw approvals allowlist add 'github*' 2>/dev/null || true
    openclaw approvals allowlist add 'gh*' 2>/dev/null || true
    openclaw approvals allowlist add 'git*' 2>/dev/null || true
    openclaw approvals allowlist add 'npm*' 2>/dev/null || true
    openclaw approvals allowlist add 'node*' 2>/dev/null || true
    openclaw approvals allowlist add 'curl*' 2>/dev/null || true
    openclaw approvals allowlist add 'wget*' 2>/dev/null || true
    openclaw approvals allowlist add 'bash*' 2>/dev/null || true
    openclaw approvals allowlist add 'sh*' 2>/dev/null || true
    openclaw approvals allowlist add 'python*' 2>/dev/null || true
    openclaw approvals allowlist add 'pip*' 2>/dev/null || true
    openclaw approvals allowlist add 'sudo*' 2>/dev/null || true

    echo 'Final approval bypass verification:'
    echo '  approvals.exec.enabled:' \$(openclaw config get approvals.exec.enabled 2>/dev/null || echo 'not set')
    echo '  gateway.mode:' \$(openclaw config get gateway.mode 2>/dev/null || echo 'not set')
    echo '  allowlist entries:' \$(openclaw approvals allowlist list 2>/dev/null | wc -l || echo '0')
  " 2>&1 || echo "  Warning: Could not reinforce approval bypass configuration"
fi

# ============================================================
# Final status check
# ============================================================

echo
SERVICE_STATUS="$(orb -m "$VM_NAME" -u root systemctl is-active openclaw 2>/dev/null || true)"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${OPENCLAW_PORT}" 2>/dev/null || true)"

GATEWAY_TOKEN="$(orb -m "$VM_NAME" -u root bash -c "cat /home/${SVC_USER}/.openclaw/openclaw.json" 2>/dev/null | jq -r '.gateway.auth.token // empty' 2>/dev/null || true)"

if [ "$SERVICE_STATUS" = "active" ] && [ "$HTTP_CODE" = "200" ]; then
  echo "============================================"
  echo "  OpenClaw is RUNNING"
  echo "============================================"
  echo
  echo "  URL:     http://localhost:${OPENCLAW_PORT}"
  echo "  Service: active"
  echo "  HTTP:    ${HTTP_CODE}"
  echo "  Model:   ${DEFAULT_MODEL}"
  [ -n "${ANTHROPIC_CONFIGURED:-}" ] && echo "  Anthropic: configured"
  [ -n "${OPENAI_CONFIGURED:-}" ] && echo "  OpenAI:    configured"
  [ -n "${GITHUB_CONFIGURED:-}" ] && echo "  GitHub:    configured"
  [ -n "${TELEGRAM_CONFIGURED:-}" ] && echo "  Telegram:  configured"
  [ -n "${GWS_CONFIGURED:-}" ] && echo "  Google:    configured"
  echo

  # Open the dashboard with auto-auth token
  if [ -n "$GATEWAY_TOKEN" ]; then
    echo "Opening dashboard in browser..."
    open "http://localhost:${OPENCLAW_PORT}/?token=${GATEWAY_TOKEN}"
  fi

  # Send Telegram notification with auto-auth URL
  if [ -n "${TELEGRAM_CONFIGURED:-}" ] && [ -n "${TELEGRAM_USER_ID:-}" ]; then
    # Use config-specific token if available, otherwise fall back to .env.local
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
      TELEGRAM_TOKEN_VAL="$TELEGRAM_BOT_TOKEN"
    else
      TELEGRAM_TOKEN_VAL="$(grep '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2-)"
    fi
    if [ -n "$GATEWAY_TOKEN" ]; then
      TG_URL="http://localhost:${OPENCLAW_PORT}/?token=${GATEWAY_TOKEN}"
    else
      TG_URL="http://localhost:${OPENCLAW_PORT}"
    fi
    curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN_VAL}/sendMessage" \
      -d chat_id="${TELEGRAM_USER_ID}" \
      -d text="OpenClaw is ready at ${TG_URL}" \
      >/dev/null 2>&1 || true
  fi
else
  echo "============================================"
  echo "  WARNING: OpenClaw may not be fully ready"
  echo "============================================"
  echo
  echo "  Service: ${SERVICE_STATUS}"
  echo "  HTTP:    ${HTTP_CODE}"
  echo
fi

if [ -n "${GWS_CONFIGURED:-}" ]; then
  echo "============================================"
  echo "  GOOGLE WORKSPACE — OAuth"
  echo "============================================"
  echo

  GWS_AUTHED=""

  # Ensure gws CLI is available on the Mac
  if ! command -v gws >/dev/null 2>&1; then
    echo "  Installing gws CLI on Mac..."
    npm install -g @googleworkspace/cli@latest >/dev/null 2>&1
  fi

  # Check if Mac already has valid gws credentials with full scopes (from a previous setup)
  if command -v gws >/dev/null 2>&1 && gws auth status 2>/dev/null | grep -q '"has_refresh_token": true' && \
     gws auth status 2>/dev/null | grep -q 'https://www.googleapis.com/auth/cloud-platform'; then
    echo "  Found existing Google credentials on Mac — exporting to VM..."
    gws auth export --unmasked 2>/dev/null | grep -v 'keyring' | orb -m "$VM_NAME" -u root bash -c "
      cat > /home/$SVC_USER/.config/gws/credentials.json
      chmod 600 /home/$SVC_USER/.config/gws/credentials.json
      chown $SVC_USER:$SVC_USER /home/$SVC_USER/.config/gws/credentials.json
    "
    # Copy Mac's client_secret.json to VM too (matches the credentials)
    if [ -f ~/.config/gws/client_secret.json ]; then
      cat ~/.config/gws/client_secret.json | orb -m "$VM_NAME" -u root bash -c "
        cat > /home/$SVC_USER/.config/gws/client_secret.json
        chmod 600 /home/$SVC_USER/.config/gws/client_secret.json
        chown $SVC_USER:$SVC_USER /home/$SVC_USER/.config/gws/client_secret.json
      "
    fi
    GWS_AUTHED="1"
    echo "  Google Workspace: authenticated (reused existing credentials)"
  else
    # No existing auth — try interactive login
    echo "  A browser window will open for Google sign-in."
    echo "  Authorize access, then return here."
    echo
    mkdir -p ~/.config/gws
    cp "$GWS_SECRET_FILE" ~/.config/gws/client_secret.json
    if gws auth login --full; then
      echo "  Exporting credentials to VM..."
      gws auth export --unmasked 2>/dev/null | grep -v 'keyring' | orb -m "$VM_NAME" -u root bash -c "
        cat > /home/$SVC_USER/.config/gws/credentials.json
        chmod 600 /home/$SVC_USER/.config/gws/credentials.json
        chown $SVC_USER:$SVC_USER /home/$SVC_USER/.config/gws/credentials.json
      "
      GWS_AUTHED="1"
      echo "  Google Workspace: authenticated"
    else
      echo
      echo "  OAuth login failed. Complete it later:"
      echo "  gws auth login --full"
      echo "  gws auth export --unmasked | orb -m ${VM_NAME} -u root bash -c \\"
      echo "    'cat > /home/${SVC_USER}/.config/gws/credentials.json && chmod 600 /home/${SVC_USER}/.config/gws/credentials.json && chown ${SVC_USER}:${SVC_USER} /home/${SVC_USER}/.config/gws/credentials.json'"
    fi
  fi
  echo
fi

echo "============================================"
echo "  USEFUL COMMANDS (run in Mac terminal)"
echo "============================================"
echo
echo "# Check service status:"
echo "  orb -m ${VM_NAME} -u root systemctl status openclaw"
echo
echo "# Run onboarding (interactive key setup):"
echo "  orb -m ${VM_NAME} -u root su -s /bin/bash ${SVC_USER} -c 'openclaw onboard'"
echo
echo "# Open the UI:"
echo "  open http://localhost:${OPENCLAW_PORT}"
echo
echo "# View logs:"
echo "  orb -m ${VM_NAME} -u root journalctl -u openclaw -f"
echo
echo "# Rebuild from scratch:"
echo "  orb delete ${VM_NAME}"
echo "  ./setup.sh"
