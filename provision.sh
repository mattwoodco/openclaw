#!/usr/bin/env bash
# Exit immediately on any error, unset variable, or pipe failure
set -Eeuo pipefail

# ============================================================
# OpenClaw Clone-Based VM Provisioning
# ============================================================
#
# Instead of building every bot VM from scratch (~8 min each),
# this script builds ONE base VM via setup.sh, then clones it
# per bot via `orb clone` (seconds). Each clone gets its own
# port, Telegram token, workspace mount, and device pairing.
#
# Usage:
#   ./provision.sh all                    # Build base + clone all bots
#   ./provision.sh bubba                  # Clone just bubba
#   ./provision.sh bubba quinn            # Clone specific bots
#   ./provision.sh rebuild-base           # Force-rebuild openclaw-base
#   ./provision.sh validate <name|all>    # Run validation checks
#   ./provision.sh status                 # Status dashboard
#
# ============================================================

# --- Constants ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="$SCRIPT_DIR/configs"
SKILLS_SRC="$SCRIPT_DIR/skills"
ENV_FILE="$SCRIPT_DIR/.env.local"
BASE_VM_NAME="openclaw-base"
BASE_PORT="18789"
SVC_USER="ocagent"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Global flags ---
FORCE=false

# Strip --force from args early so it does not interfere with the command router
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--force" ]; then
    FORCE=true
  else
    ARGS+=("$arg")
  fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

# --- Source validate.sh if available, otherwise stub ---
if [ -f "$SCRIPT_DIR/validate.sh" ]; then
  # shellcheck source=./validate.sh
  source "$SCRIPT_DIR/validate.sh"
else
  validate_vm() { echo -e "${YELLOW}Warning: validate.sh not found, skipping validation${NC}"; }
fi

# ============================================================
# Helper functions
# ============================================================

usage() {
  cat <<EOF
${BOLD}OpenClaw Clone-Based VM Provisioning${NC}

Usage: $0 <command> [options] [vm-names...]

Commands:
  all                          Build base if needed, clone + customize all bots
  <name> [name...]             Clone + customize specific bot(s)
  rebuild-base                 Force-rebuild ${BASE_VM_NAME}
  validate <name|all>          Run validation checks
  status                       Status dashboard

Options:
  --force                      Skip confirmation prompts

Examples:
  $0 all
  $0 bubba
  $0 bubba quinn
  $0 rebuild-base
  $0 validate all
  $0 status
EOF
}

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check if a VM exists and optionally get its status.
# Uses cached orb list to avoid SIGPIPE issues with `orb list | grep -q` under pipefail.
vm_exists() {
  local name="$1"
  local _orb_out
  _orb_out="$(orb list 2>/dev/null || true)"
  echo "$_orb_out" | grep -q "^${name} "
}

vm_status() {
  local name="$1"
  local _orb_out
  _orb_out="$(orb list 2>/dev/null || true)"
  echo "$_orb_out" | grep "^${name} " | awk '{print $2}'
}

vm_is_running() {
  local name="$1"
  [ "$(vm_status "$name")" = "running" ]
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log_error "Required command not found: $1"
    case "$1" in
      orb) echo "  Install OrbStack from https://orbstack.dev" >&2 ;;
      jq)  echo "  Install with: brew install jq" >&2 ;;
      *)   echo "  This is a standard utility -- check your PATH" >&2 ;;
    esac
    exit 1
  }
}

# List all bot config names (basenames without .env)
get_all_configs() {
  local configs=()
  for config_file in "$CONFIGS_DIR"/*.env; do
    if [ -f "$config_file" ]; then
      configs+=("$(basename "$config_file" .env)")
    fi
  done
  echo "${configs[@]+"${configs[@]}"}"
}

# Load a bot config into the current shell.
# Sources .env.local first (shared keys), then configs/$name.env.
load_config() {
  local name="$1"
  local config_file="$CONFIGS_DIR/$name.env"

  if [ ! -f "$config_file" ]; then
    log_error "Configuration '$name' not found at $config_file"
    return 1
  fi

  # Source .env.local for shared keys (ANTHROPIC_API_KEY, GITHUB_TOKEN, etc.)
  if [ -f "$ENV_FILE" ]; then
    set +u
    # shellcheck source=./.env.local
    source "$ENV_FILE"
    set -u
  fi

  # Source the bot-specific config (overrides shared keys if set explicitly)
  set +u
  # shellcheck source=/dev/null
  source "$config_file"
  set -u

  # Validate required vars
  : "${VM_NAME:?VM_NAME not set in $config_file}"
  : "${OPENCLAW_PORT:?OPENCLAW_PORT not set in $config_file}"
  : "${WORKSPACE_DIR:?WORKSPACE_DIR not set in $config_file}"

  # Resolve WORKSPACE_DIR to absolute path
  if [[ "$WORKSPACE_DIR" != /* ]]; then
    WORKSPACE_DIR="$SCRIPT_DIR/${WORKSPACE_DIR#./}"
  fi

  # Resolve TELEGRAM_BOT_TOKEN -- may reference .env.local vars (already sourced)
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"

  # MAC_WORKSPACE_DIR is the absolute Mac path
  MAC_WORKSPACE_DIR="$WORKSPACE_DIR"

  # MAC_WORKSPACE_PATH is the mount path inside /mnt/mac (strip leading /)
  MAC_WORKSPACE_PATH="${MAC_WORKSPACE_DIR#/}"
}

# Ensure OrbStack is running
ensure_orbstack() {
  if ! orb status >/dev/null 2>&1; then
    log_info "Starting OrbStack..."
    orb start >/dev/null || { log_error "OrbStack failed to start"; exit 1; }
    local i
    for i in $(seq 1 15); do
      orb status >/dev/null 2>&1 && break
      sleep 1
    done
    orb status >/dev/null 2>&1 || { log_error "OrbStack did not become ready within 15 seconds"; exit 1; }
  fi
}

# ============================================================
# 1. build_base
# ============================================================

build_base() {
  # If base VM already exists and is stopped, skip
  if vm_exists "$BASE_VM_NAME"; then
    local state
    state="$(vm_status "$BASE_VM_NAME")"
    if [ "$state" = "stopped" ] || [ "$state" = "running" ]; then
      log_success "Base VM '${BASE_VM_NAME}' already exists (state: $state)"
      # Ensure it is stopped for cloning
      if [ "$state" = "running" ]; then
        log_info "Stopping base VM for clone readiness..."
        orb stop "$BASE_VM_NAME"
      fi
      return 0
    fi
  fi

  log_info "Building base VM '${BASE_VM_NAME}' via setup.sh (this takes ~8 minutes)..."
  local start_time
  start_time="$(date +%s)"

  # setup.sh needs a workspace dir for realpath
  mkdir -p "$SCRIPT_DIR/workspace-base"

  # Run setup.sh with base VM settings
  if ! timeout 600 bash -c "
    VM_NAME='${BASE_VM_NAME}' \
    OPENCLAW_PORT='${BASE_PORT}' \
    MAC_WORKSPACE_DIR='${SCRIPT_DIR}/workspace-base' \
    bash '${SCRIPT_DIR}/setup.sh'
  "; then
    log_error "Base VM build failed or timed out (600s limit)"
    return 1
  fi

  # Write version marker
  orb -m "$BASE_VM_NAME" -u root bash -c "date +%s > /etc/openclaw-base-version"

  # Stop the base so it can be cloned
  log_info "Stopping base VM for clone readiness..."
  orb stop "$BASE_VM_NAME"

  local end_time elapsed
  end_time="$(date +%s)"
  elapsed="$((end_time - start_time))"
  log_success "Base VM built in ${elapsed}s"
}

# ============================================================
# 2. apply_bot_config
# ============================================================

apply_bot_config() {
  local name="$1"
  log_info "Applying bot config for '$name'..."

  # Load config into current shell
  load_config "$name"

  # Run a single orb exec that does all config changes atomically
  orb -m "$VM_NAME" -u root bash -c "
    set -Eeuo pipefail

    # --- a) Rewrite openclaw.json via jq ---
    OC_JSON='/home/${SVC_USER}/.openclaw/openclaw.json'
    if [ -f \"\$OC_JSON\" ]; then
      jq --argjson port ${OPENCLAW_PORT} \\
         --arg token \"${TELEGRAM_BOT_TOKEN}\" \\
         --arg o1 \"http://localhost:${OPENCLAW_PORT}\" \\
         --arg o2 \"http://127.0.0.1:${OPENCLAW_PORT}\" \\
         '.gateway.port=\$port | .gateway.bind=\"0.0.0.0\" | del(.gateway.auth) |
          .gateway.controlUi.allowedOrigins=[\$o1,\$o2] |
          .channels.telegram.botToken=\$token |
          .channels.telegram.execApprovals.enabled=true' \\
         \"\$OC_JSON\" > /tmp/oc-cfg.json
      mv /tmp/oc-cfg.json \"\$OC_JSON\"
      chown ${SVC_USER}:${SVC_USER} \"\$OC_JSON\"
      chmod 600 \"\$OC_JSON\"
    else
      echo 'Warning: openclaw.json not found, skipping jq rewrite' >&2
    fi

    # --- b) Rewrite mac-isolation.service bind-mount path ---
    if [ -f /etc/systemd/system/mac-isolation.service ]; then
      sed -i \"s|mount --bind \\\"/mnt/mac/[^\\\"]*\\\"|mount --bind \\\"/mnt/mac/${MAC_WORKSPACE_PATH}\\\"|\" \\
          /etc/systemd/system/mac-isolation.service
      systemctl daemon-reload
    fi

    # --- c) Swap UFW port from base to bot ---
    ufw delete allow in on lo to any port ${BASE_PORT} proto tcp 2>/dev/null || true
    ufw delete allow in on eth0 to any port ${BASE_PORT} proto tcp 2>/dev/null || true
    ufw allow in on lo to any port ${OPENCLAW_PORT} proto tcp >/dev/null
    ufw allow in on eth0 to any port ${OPENCLAW_PORT} proto tcp >/dev/null

    # --- d) Clear stale device pairings ---
    rm -f /home/${SVC_USER}/.openclaw/devices/paired.json \
          /home/${SVC_USER}/.openclaw/devices/pending.json
  "

  log_success "Bot config applied for '$name' (port=${OPENCLAW_PORT})"
}

# ============================================================
# 3. start_services
# ============================================================

start_services() {
  local name="$1"
  log_info "Starting services for '$name'..."

  # Load config
  load_config "$name"

  # Create workspace dir on Mac
  mkdir -p "$MAC_WORKSPACE_DIR"

  # Copy skills if skills dir exists
  if [ -d "$SKILLS_SRC" ] && [ "$(ls -A "$SKILLS_SRC" 2>/dev/null)" ]; then
    mkdir -p "$MAC_WORKSPACE_DIR/skills"
    cp -r "$SKILLS_SRC"/* "$MAC_WORKSPACE_DIR/skills/"
    log_info "Skills copied to workspace"
  fi

  # Copy workspace template files (don't overwrite existing)
  local template_files=(AGENTS.md SOUL.md USER.md IDENTITY.md TOOLS.md HEARTBEAT.md BOOTSTRAP.md)
  local template_src=""

  # Check for a workspace-templates dir first
  if [ -d "$SCRIPT_DIR/workspace-templates" ]; then
    template_src="$SCRIPT_DIR/workspace-templates"
  # Then check workspace-base (created by setup.sh for base VM)
  elif [ -d "$SCRIPT_DIR/workspace-base" ]; then
    template_src="$SCRIPT_DIR/workspace-base"
  fi

  if [ -n "$template_src" ]; then
    for tpl in "${template_files[@]}"; do
      if [ -f "$template_src/$tpl" ] && [ ! -f "$MAC_WORKSPACE_DIR/$tpl" ]; then
        cp "$template_src/$tpl" "$MAC_WORKSPACE_DIR/$tpl"
      fi
    done
    log_info "Workspace template files synced (existing files preserved)"
  fi

  # Bind-mount workspace into VM
  orb -m "$VM_NAME" -u root bash -c "
    set -Eeuo pipefail
    mkdir -p /workspace/vm-openclaw
    umount /workspace/vm-openclaw 2>/dev/null || true
    umount /mnt/mac 2>/dev/null || true
    mount --bind '/mnt/mac/${MAC_WORKSPACE_PATH}' /workspace/vm-openclaw
    chown ${SVC_USER}:${SVC_USER} /workspace/vm-openclaw
    mount -t tmpfs -o size=0,ro tmpfs /mnt/mac
    systemctl reset-failed mac-isolation.service 2>/dev/null || true
  "
  log_info "Workspace mounted: /workspace/vm-openclaw -> $MAC_WORKSPACE_DIR"

  # Export GWS credentials from Mac if available
  if command -v gws >/dev/null 2>&1 && gws auth status 2>/dev/null | grep -q '"has_refresh_token": true'; then
    log_info "Exporting Google Workspace credentials to VM..."
    gws auth export --unmasked 2>/dev/null | grep -v 'keyring' | orb -m "$VM_NAME" -u root bash -c "
      mkdir -p /home/${SVC_USER}/.config/gws
      cat > /home/${SVC_USER}/.config/gws/credentials.json
      chmod 600 /home/${SVC_USER}/.config/gws/credentials.json
      chown ${SVC_USER}:${SVC_USER} /home/${SVC_USER}/.config/gws/credentials.json
    "
    log_success "GWS credentials exported"
  fi

  # Copy client_secret.json if it exists on Mac
  if [ -f ~/.config/gws/client_secret.json ]; then
    cat ~/.config/gws/client_secret.json | orb -m "$VM_NAME" -u root bash -c "
      mkdir -p /home/${SVC_USER}/.config/gws
      cat > /home/${SVC_USER}/.config/gws/client_secret.json
      chmod 600 /home/${SVC_USER}/.config/gws/client_secret.json
      chown ${SVC_USER}:${SVC_USER} /home/${SVC_USER}/.config/gws/client_secret.json
    "
    log_info "GWS client_secret.json copied to VM"
  fi

  # Restart services
  orb -m "$VM_NAME" -u root bash -c "systemctl restart headless-chrome openclaw"

  # Wait for HTTP 200 (up to 30 seconds, 2s interval)
  log_info "Waiting for gateway on port ${OPENCLAW_PORT}..."
  local ready=0
  local attempt
  for attempt in $(seq 1 15); do
    if curl -s -o /dev/null -w '' "http://localhost:${OPENCLAW_PORT}" 2>/dev/null; then
      ready=1
      break
    fi
    printf '.' >&2
    sleep 2
  done
  echo '' >&2

  if [ "$ready" -ne 1 ]; then
    log_warn "Gateway not responding on port ${OPENCLAW_PORT} after 30s"
    log_warn "Check: orb -m ${VM_NAME} -u root journalctl -u openclaw -f"
    return 1
  fi

  # Approve CLI device
  orb -m "$VM_NAME" -u root su -s /bin/bash "$SVC_USER" -c \
    "openclaw gateway health >/dev/null 2>&1 || true"
  sleep 2

  local pending_id
  pending_id="$(orb -m "$VM_NAME" -u root bash -c \
    "cat /home/${SVC_USER}/.openclaw/devices/pending.json 2>/dev/null" \
    | jq -r 'keys[0] // empty' 2>/dev/null || true)"

  if [ -n "$pending_id" ]; then
    orb -m "$VM_NAME" -u root su -s /bin/bash "$SVC_USER" -c \
      "openclaw devices approve ${pending_id}" 2>&1 || true
    log_info "CLI device approved (${pending_id})"
  else
    log_info "CLI device already approved (or none pending)"
  fi

  # Reinforce approval bypass
  orb -m "$VM_NAME" -u root su -s /bin/bash "$SVC_USER" -c "
    openclaw approvals allowlist add '*' 2>/dev/null || true
    openclaw approvals allowlist add 'gws*' 2>/dev/null || true
    openclaw approvals allowlist add 'bash*' 2>/dev/null || true
    openclaw approvals allowlist add 'sh*' 2>/dev/null || true
  "
  log_info "Approval bypass allowlist configured"

  # Read and display gateway auth token
  local gateway_token
  gateway_token="$(orb -m "$VM_NAME" -u root bash -c \
    "cat /home/${SVC_USER}/.openclaw/openclaw.json" 2>/dev/null \
    | jq -r '.gateway.auth.token // empty' 2>/dev/null || true)"

  echo ""
  echo -e "${GREEN}${BOLD}============================================${NC}"
  echo -e "${GREEN}${BOLD}  $name is RUNNING${NC}"
  echo -e "${GREEN}${BOLD}============================================${NC}"
  echo ""
  if [ -n "$gateway_token" ]; then
    echo -e "  URL:  http://localhost:${OPENCLAW_PORT}/?token=${gateway_token}"
  else
    echo -e "  URL:  http://localhost:${OPENCLAW_PORT}"
  fi
  echo -e "  VM:   orb -m ${VM_NAME}"
  echo -e "  Logs: orb -m ${VM_NAME} -u root journalctl -u openclaw -f"
  echo ""
}

# ============================================================
# 4. clone_and_customize
# ============================================================

clone_and_customize() {
  local name="$1"
  local start_time
  start_time="$(date +%s)"

  echo ""
  echo -e "${BLUE}${BOLD}=== Provisioning bot: $name ===${NC}"

  # Load config to get VM_NAME
  load_config "$name"

  # Check if VM already exists
  if vm_exists "$VM_NAME"; then
    if [ "$FORCE" = true ]; then
      log_warn "VM '${VM_NAME}' exists -- deleting (--force)"
    else
      echo -e "${YELLOW}VM '${VM_NAME}' already exists. Delete and recreate? [y/N]${NC}"
      local confirm
      read -r confirm
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Skipped: $name"
        return 0
      fi
    fi
    orb delete "$VM_NAME" --force 2>/dev/null || true
    sleep 1
  fi

  # Clone from base
  log_info "Cloning ${BASE_VM_NAME} -> ${VM_NAME}..."
  orb clone "$BASE_VM_NAME" "$VM_NAME"

  # Start the clone and wait for it to be running
  log_info "Starting ${VM_NAME}..."
  orb start "$VM_NAME"

  local running=0
  local attempt
  for attempt in $(seq 1 15); do
    if vm_is_running "$VM_NAME"; then
      running=1
      break
    fi
    sleep 2
  done

  if [ "$running" -ne 1 ]; then
    log_error "VM '${VM_NAME}' failed to start within 30s"
    return 1
  fi

  log_success "VM '${VM_NAME}' is running"

  # Apply bot-specific config
  apply_bot_config "$name"

  # Start services and validate
  start_services "$name"

  local end_time elapsed
  end_time="$(date +%s)"
  elapsed="$((end_time - start_time))"
  log_success "Bot '$name' provisioned in ${elapsed}s"
}

# ============================================================
# 5. build_base_if_needed
# ============================================================

build_base_if_needed() {
  if vm_exists "$BASE_VM_NAME"; then
    log_success "Base VM '${BASE_VM_NAME}' exists"
    # Ensure it is stopped for cloning
    if vm_is_running "$BASE_VM_NAME"; then
      log_info "Stopping base VM for clone readiness..."
      orb stop "$BASE_VM_NAME"
    fi
  else
    build_base
  fi
}

# ============================================================
# 6. show_status (stub -- overridden by validate.sh if present)
# ============================================================

# Only define if validate.sh didn't already define it
if ! declare -f show_status >/dev/null 2>&1; then
show_status() {
  echo ""
  echo -e "${BLUE}${BOLD}=== OpenClaw Provisioning Status ===${NC}"
  echo ""

  # Base VM status
  local base_status="missing"
  local base_age="n/a"
  if vm_exists "$BASE_VM_NAME"; then
    base_status="$(vm_status "$BASE_VM_NAME")"
    local version_ts
    version_ts="$(orb -m "$BASE_VM_NAME" -u root bash -c 'cat /etc/openclaw-base-version 2>/dev/null' 2>/dev/null || true)"
    if [ -n "$version_ts" ]; then
      local now
      now="$(date +%s)"
      local age_s="$((now - version_ts))"
      if [ "$age_s" -lt 3600 ]; then
        base_age="$((age_s / 60))m ago"
      elif [ "$age_s" -lt 86400 ]; then
        base_age="$((age_s / 3600))h ago"
      else
        base_age="$((age_s / 86400))d ago"
      fi
    fi
  fi

  printf "  %-18s %-8s %-12s %-10s %-8s %-12s\n" "NAME" "PORT" "VM_STATUS" "SERVICE" "HTTP" "BASE_AGE"
  printf "  %-18s %-8s %-12s %-10s %-8s %-12s\n" "----" "----" "---------" "-------" "----" "--------"
  printf "  %-18s %-8s %-12s %-10s %-8s %-12s\n" "$BASE_VM_NAME" "$BASE_PORT" "$base_status" "-" "-" "$base_age"

  # Per-bot status
  local configs
  configs="$(get_all_configs)"
  if [ -z "$configs" ]; then
    echo ""
    log_warn "No bot configurations found in $CONFIGS_DIR"
    return
  fi

  for cfg_name in $configs; do
    local vm_status="not-created" svc_status="-" http_status="-"
    local cfg_file="$CONFIGS_DIR/$cfg_name.env"

    # Read port from config without polluting env
    local port
    port="$(grep '^OPENCLAW_PORT=' "$cfg_file" | cut -d= -f2 || echo '?')"
    local vm
    vm="$(grep '^VM_NAME=' "$cfg_file" | cut -d= -f2 || echo "$cfg_name")"

    if vm_exists "$vm"; then
      vm_status="$(vm_status "$vm")"

      if [ "$vm_status" = "running" ]; then
        svc_status="$(orb -m "$vm" -u root systemctl is-active openclaw 2>/dev/null || echo 'inactive')"

        local http_code
        http_code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${port}" 2>/dev/null || echo '000')"
        if [ "$http_code" = "200" ]; then
          http_status="200"
        else
          http_status="$http_code"
        fi
      fi
    fi

    printf "  %-18s %-8s %-12s %-10s %-8s %-12s\n" "$cfg_name" "$port" "$vm_status" "$svc_status" "$http_status" "-"
  done

  echo ""
}
fi

# ============================================================
# 7. main -- command router
# ============================================================

main() {
  require_cmd orb
  require_cmd jq
  require_cmd curl
  ensure_orbstack

  case "${1:-}" in
    all)
      local all_configs
      all_configs="$(get_all_configs)"
      if [ -z "$all_configs" ]; then
        log_error "No configurations found in $CONFIGS_DIR"
        echo "  Create one with: ./manage.sh scaffold <name>"
        exit 1
      fi

      echo -e "${BLUE}${BOLD}Provisioning all bots: ${all_configs}${NC}"

      if [ "$FORCE" != true ]; then
        echo -n "Continue? [y/N] "
        local confirm
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
          echo "Cancelled."
          exit 0
        fi
      fi

      build_base_if_needed

      for cfg_name in $all_configs; do
        clone_and_customize "$cfg_name"
        validate_vm "$cfg_name"
      done

      echo ""
      show_status
      ;;

    rebuild-base)
      log_warn "Destroying and rebuilding ${BASE_VM_NAME}..."
      orb delete "$BASE_VM_NAME" --force 2>/dev/null || true
      sleep 1
      build_base
      log_success "Base VM rebuilt. Run './provision.sh all' to re-clone bots."
      ;;

    validate)
      shift
      if [ "${1:-}" = "all" ] || [ -z "${1:-}" ]; then
        local all_configs
        all_configs="$(get_all_configs)"
        if [ -z "$all_configs" ]; then
          log_error "No configurations found"
          exit 1
        fi
        for cfg_name in $all_configs; do
          validate_vm "$cfg_name"
        done
      else
        for cfg_name in "$@"; do
          validate_vm "$cfg_name"
        done
      fi
      ;;

    status)
      show_status
      ;;

    -h|--help|help)
      usage
      ;;

    "")
      usage
      exit 1
      ;;

    *)
      # Provision specific bots by name
      build_base_if_needed

      for cfg_name in "$@"; do
        clone_and_customize "$cfg_name"
        validate_vm "$cfg_name"
      done
      ;;
  esac
}

main "$@"
