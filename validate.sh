#!/bin/bash
# OpenClaw VM Validation & Status Script
# Sourced by provision.sh — also works standalone.
# Usage (standalone): source validate.sh && validate_vm bubba

# If sourced standalone, apply strict mode and define missing constants/helpers.
if [ -z "${SCRIPT_DIR:-}" ]; then
    set -Eeuo pipefail
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
: "${CONFIGS_DIR:=$SCRIPT_DIR/configs}"
: "${ENV_FILE:=$SCRIPT_DIR/.env.local}"
: "${SVC_USER:=ocagent}"
: "${BASE_VM_NAME:=openclaw-base}"
: "${BASE_PORT:=18789}"
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[1;33m}"
: "${BLUE:=\033[0;34m}"
: "${NC:=\033[0m}"

# Fallback load_config when provision.sh has not been sourced.
if ! declare -f load_config >/dev/null 2>&1; then
    load_config() {
        local name="$1"
        local config_file="$CONFIGS_DIR/$name.env"
        if [ ! -f "$config_file" ]; then
            echo -e "${RED}Error: Configuration '$name' not found${NC}"
            return 1
        fi
        # Source .env.local first so variable references resolve
        if [ -f "$ENV_FILE" ]; then
            set +u
            source "$ENV_FILE"
            set -u
        fi
        set +u
        source "$config_file"
        set -u
        : "${VM_NAME:?VM_NAME not set in $config_file}"
        : "${OPENCLAW_PORT:?OPENCLAW_PORT not set in $config_file}"
    }
fi

# ---------------------------------------------------------------------------
# validate_vm — run 4 validation checks against a provisioned VM
# ---------------------------------------------------------------------------
validate_vm() {
    local name="$1"
    local failures=0

    # Load configuration to get VM_NAME, OPENCLAW_PORT, BOT_NAME
    if ! load_config "$name"; then
        return 1
    fi

    local vm="${VM_NAME}"
    local port="${OPENCLAW_PORT}"
    local bot="${BOT_NAME:-$vm}"

    echo -e "${BLUE}Validating: ${name} (port ${port})${NC}"

    # ------------------------------------------------------------------
    # Check 1: Service active
    # ------------------------------------------------------------------
    local service_status
    service_status=$(orb -m "$vm" -u root systemctl is-active openclaw 2>/dev/null || echo "inactive")

    if [ "$service_status" = "active" ]; then
        echo -e "  ${GREEN}✓${NC} Service: active"
    else
        echo -e "  ${RED}✗${NC} Service: ${service_status}"
        ((failures++))
    fi

    # ------------------------------------------------------------------
    # Check 2: HTTP responding
    # ------------------------------------------------------------------
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://localhost:$port" 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ]; then
        echo -e "  ${GREEN}✓${NC} HTTP: 200"
    else
        echo -e "  ${RED}✗${NC} HTTP: ${http_code}"
        ((failures++))
    fi

    # ------------------------------------------------------------------
    # Check 3: Email sending works
    # ------------------------------------------------------------------
    echo -ne "  ${YELLOW}…${NC} Email: checking (this may take ~30s)...\r"

    local email_result
    email_result=$(orb -m "$vm" -u root su -s /bin/bash "$SVC_USER" -c \
        "openclaw agent --session-id validate-email --message 'Send a brief test email to matt@mattwood.co using gws gmail +send --html. Subject: Test from ${bot} ($(date +%H:%M)). Keep the HTML simple - just a short confirmation message.' --json --timeout 90" 2>&1) || true

    local email_ok=false
    local email_detail="unknown failure"

    if echo "$email_result" | grep -q '"aborted": false' && echo "$email_result" | grep -q '"status": "ok"'; then
        email_ok=true
        # Try to extract a message ID from the payloads
        local msg_id
        msg_id=$(echo "$email_result" | grep -oE '"messageId"\s*:\s*"[^"]+"' | head -1 | grep -oE '"[^"]+"\s*$' | tr -d '"' | xargs 2>/dev/null || true)
        if [ -z "$msg_id" ]; then
            # Fallback: look for any hex-looking ID in the output
            msg_id=$(echo "$email_result" | grep -oE '[0-9a-f]{12,}' | head -1 || true)
        fi
        if [ -n "$msg_id" ]; then
            email_detail="sent (${msg_id})"
        else
            email_detail="sent"
        fi
    else
        # Attempt to extract a useful reason
        if echo "$email_result" | grep -qi 'timeout\|timed out'; then
            email_detail="failed (agent timed out)"
        elif echo "$email_result" | grep -qi 'aborted.*true'; then
            email_detail="failed (agent aborted)"
        else
            email_detail="failed"
        fi
    fi

    # Overwrite the "checking..." line
    if $email_ok; then
        echo -e "  ${GREEN}✓${NC} Email: ${email_detail}          "
    else
        echo -e "  ${RED}✗${NC} Email: ${email_detail}          "
        ((failures++))
    fi

    # ------------------------------------------------------------------
    # Check 4: Dashboard opens
    # ------------------------------------------------------------------
    local gateway_token
    gateway_token=$(orb -m "$vm" -u root bash -c \
        "cat /home/$SVC_USER/.openclaw/openclaw.json" 2>/dev/null \
        | jq -r '.gateway.auth.token // empty' 2>/dev/null || true)

    local dashboard_status
    if [ -n "$gateway_token" ]; then
        open "http://localhost:${port}/?token=${gateway_token}" 2>/dev/null || true
        dashboard_status="opened"
    else
        open "http://localhost:${port}" 2>/dev/null || true
        dashboard_status="opened (no token)"
    fi

    echo -e "  ${GREEN}✓${NC} Dashboard: ${dashboard_status}"

    # ------------------------------------------------------------------
    # Result
    # ------------------------------------------------------------------
    if [ "$failures" -gt 0 ]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# show_status — print a status dashboard for the base VM and all bots
# ---------------------------------------------------------------------------
show_status() {
    echo -e "${BLUE}=== OpenClaw Provisioning Status ===${NC}"
    echo ""

    # --- Base VM section ---
    echo -e "Base VM: ${BLUE}${BASE_VM_NAME}${NC}"

    local base_exists=false
    local base_vm_status="not found"
    local _orb_base
    _orb_base=$(orb list 2>/dev/null || true)
    if echo "$_orb_base" | grep -q "^${BASE_VM_NAME} "; then
        base_exists=true
        base_vm_status=$(echo "$_orb_base" | grep "^${BASE_VM_NAME} " | awk '{print $2}')
    fi

    if $base_exists; then
        local build_ts
        local raw_ts
        raw_ts=$(orb -m "$BASE_VM_NAME" -u root cat /etc/openclaw-base-version 2>/dev/null || echo "")
        if [ -n "$raw_ts" ] && [ "$raw_ts" != "unknown" ]; then
            build_ts=$(date -r "$raw_ts" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$raw_ts")
        else
            build_ts="unknown"
        fi
        echo "  Status: ${base_vm_status} (ready for cloning)"
        echo "  Built:  ${build_ts}"
    else
        echo -e "  Status: ${RED}not built${NC} (run ./provision.sh rebuild-base)"
    fi

    echo ""

    # --- Bot VMs table ---
    echo "Bot VMs:"

    if [ ! -d "$CONFIGS_DIR" ] || [ -z "$(ls -A "$CONFIGS_DIR"/*.env 2>/dev/null)" ]; then
        echo "  No configurations found in $CONFIGS_DIR"
        return 0
    fi

    # Header
    printf "%-12s %-7s %-13s %-10s %-6s\n" "NAME" "PORT" "VM" "SERVICE" "HTTP"
    printf "%-12s %-7s %-13s %-10s %-6s\n" "─────" "────" "──" "───────" "────"

    # Cache the orb list output once
    local orb_list
    orb_list=$(orb list 2>/dev/null || true)

    for config_file in "$CONFIGS_DIR"/*.env; do
        [ -f "$config_file" ] || continue
        local cfg_name
        cfg_name=$(basename "$config_file" .env)

        # Source config in a subshell-safe way: reset vars first
        local _vm_name="" _port="" _svc="---" _http="---" _vm_status="not-created"

        (
            # Isolate variable leakage
            set +u
            [ -f "$ENV_FILE" ] && source "$ENV_FILE"
            source "$config_file"
            set -u
            echo "${VM_NAME:-} ${OPENCLAW_PORT:-}"
        ) | read -r _vm_name _port || true

        # Fallback: source directly if subshell pipe failed
        if [ -z "$_vm_name" ] || [ -z "$_port" ]; then
            set +u
            [ -f "$ENV_FILE" ] && source "$ENV_FILE"
            source "$config_file"
            set -u
            _vm_name="${VM_NAME:-}"
            _port="${OPENCLAW_PORT:-}"
        fi

        [ -z "$_vm_name" ] && continue

        # VM status
        local vm_line
        vm_line=$(echo "$orb_list" | grep "^${_vm_name} " 2>/dev/null || true)
        if [ -n "$vm_line" ]; then
            _vm_status=$(echo "$vm_line" | awk '{print $2}')
        fi

        # Service and HTTP checks — only if running
        if [ "$_vm_status" = "running" ]; then
            _svc=$(orb -m "$_vm_name" -u root systemctl is-active openclaw 2>/dev/null || echo "inactive")
            _http=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "http://localhost:$_port" 2>/dev/null || echo "000")
        fi

        # Color coding
        local vm_col svc_col http_col
        case "$_vm_status" in
            running)     vm_col="${GREEN}${_vm_status}${NC}" ;;
            stopped)     vm_col="${YELLOW}${_vm_status}${NC}" ;;
            *)           vm_col="${RED}${_vm_status}${NC}" ;;
        esac
        case "$_svc" in
            active)      svc_col="${GREEN}${_svc}${NC}" ;;
            ---)         svc_col="${_svc}" ;;
            *)           svc_col="${RED}${_svc}${NC}" ;;
        esac
        case "$_http" in
            200)         http_col="${GREEN}${_http}${NC}" ;;
            ---)         http_col="${_http}" ;;
            *)           http_col="${RED}${_http}${NC}" ;;
        esac

        # printf with color needs extra width to account for escape codes
        printf "%-12s %-7s %-13b %-22b %-18b\n" "$cfg_name" "$_port" "$vm_col" "$svc_col" "$http_col"
    done
}

# ---------------------------------------------------------------------------
# validate_all — run validate_vm for every config, then print a summary
# ---------------------------------------------------------------------------
validate_all() {
    local -a names=()
    local -a results=()
    local -a failures_list=()

    if [ ! -d "$CONFIGS_DIR" ] || [ -z "$(ls -A "$CONFIGS_DIR"/*.env 2>/dev/null)" ]; then
        echo "No configurations found in $CONFIGS_DIR"
        return 1
    fi

    for config_file in "$CONFIGS_DIR"/*.env; do
        [ -f "$config_file" ] || continue
        names+=("$(basename "$config_file" .env)")
    done

    for cfg_name in "${names[@]}"; do
        echo ""
        local passed=4
        local fail_reason=""

        # Run validate_vm and capture per-check results by parsing output
        local output
        output=$(validate_vm "$cfg_name" 2>&1) && true
        local rc=$?
        echo "$output"

        # Count failures from the output (lines containing the ✗ marker)
        local check_failures
        check_failures=$(echo "$output" | grep -c '✗' || true)
        passed=$((4 - check_failures))

        if [ "$check_failures" -gt 0 ]; then
            # Extract which checks failed
            fail_reason=$(echo "$output" | grep '✗' | sed 's/.*✗[[:space:]]*//' | paste -sd', ' -)
        fi

        results+=("$passed")
        failures_list+=("$fail_reason")
        echo ""
    done

    # Summary
    echo -e "${BLUE}=== Validation Summary ===${NC}"
    for i in "${!names[@]}"; do
        local cfg_name="${names[$i]}"
        local passed="${results[$i]}"
        local fail_reason="${failures_list[$i]}"

        if [ "$passed" -eq 4 ]; then
            printf "%-8s %s/4 checks passed ${GREEN}✓${NC}\n" "${cfg_name}:" "$passed"
        else
            printf "%-8s %s/4 checks passed ${RED}✗${NC} (%s)\n" "${cfg_name}:" "$passed" "$fail_reason"
        fi
    done
}
