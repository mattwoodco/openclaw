#!/bin/bash
set -euo pipefail

# OpenClaw VM Configuration Manager
# Usage: ./manage.sh <command> [args...]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="$SCRIPT_DIR/configs"
WORKSPACES_DIR="$SCRIPT_DIR/workspaces"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Ensure directories exist
mkdir -p "$CONFIGS_DIR" "$WORKSPACES_DIR" "$TEMPLATES_DIR"

usage() {
    echo "OpenClaw VM Configuration Manager"
    echo ""
    echo "Usage: $0 <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  scaffold <name>              Create new VM configuration"
    echo "  list                         Show all configurations"
    echo "  edit <name>                  Edit configuration in default editor"
    echo "  copy <source> <dest>         Copy configuration to new name"
    echo "  delete <name>                Delete configuration (with confirmation)"
    echo "  validate <name>              Validate configuration file"
    echo "  template <template-name>     Create from template (default, telegram-bot)"
    echo "  status                       Show configuration and VM status"
    echo ""
    echo "Examples:"
    echo "  $0 scaffold my-assistant"
    echo "  $0 copy my-assistant backup-assistant"
    echo "  $0 delete old-config"
    echo "  $0 template telegram-bot my-telegram-bot"
}

# Get next available port
get_next_port() {
    local base_port=18790
    local port=$base_port

    while [ -f "$CONFIGS_DIR"/*.env ] 2>/dev/null; do
        if grep -q "OPENCLAW_PORT=$port" "$CONFIGS_DIR"/*.env 2>/dev/null; then
            ((port++))
        else
            break
        fi
    done

    echo $port
}

# Generate configuration file
scaffold_config() {
    local name="$1"
    local config_file="$CONFIGS_DIR/$name.env"
    local workspace_dir="./workspaces/workspace-$name"
    local port=$(get_next_port)

    if [ -f "$config_file" ]; then
        echo -e "${RED}Error: Configuration '$name' already exists${NC}"
        return 1
    fi

    cat > "$config_file" << EOF
# OpenClaw VM Configuration: $name
# Generated: $(date)

# === Basic VM Settings ===
VM_NAME=$name
OPENCLAW_PORT=$port
WORKSPACE_DIR=$workspace_dir

# === Bot Identity ===
BOT_NAME="OpenClaw Assistant: $name"
BOT_DESCRIPTION="AI assistant for various tasks"

# === API Keys ===
# Inherit from environment or set specific keys
ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY}
OPENAI_API_KEY=\${OPENAI_API_KEY}

# === Service Configurations ===
# Set VM-specific tokens if needed
TELEGRAM_BOT_TOKEN=\${TELEGRAM_BOT_TOKEN_$(echo $name | tr '[:lower:]' '[:upper:]' | tr '-' '_')}
GITHUB_TOKEN=\${GITHUB_TOKEN}

# === Google Workspace ===
# Reuse existing credentials or set VM-specific
GOOGLE_WORKSPACE_CREDENTIALS_FILE=\${GOOGLE_WORKSPACE_CREDENTIALS_FILE}

# === Feature Flags ===
ENABLE_EMAIL_SENDING=true
ENABLE_CODE_EXECUTION=true
ENABLE_WEB_BROWSING=false
ENABLE_CRON_JOBS=true

# === Security & Approval Settings ===
# Set to true to skip approval prompts (less secure)
AUTO_APPROVE_EMAIL=false
AUTO_APPROVE_FILE_OPERATIONS=false
AUTO_APPROVE_WEB_REQUESTS=false

# Use wildcard allowlist to skip all approvals (development only)
OPENCLAW_SKIP_APPROVALS=false

# === Advanced Settings ===
# Memory and performance
NODE_OPTIONS="--max-old-space-size=2048"

# Logging level (debug, info, warn, error)
LOG_LEVEL=info

# Custom model configuration
# ANTHROPIC_MODEL="claude-sonnet-4-20250514"
# OPENAI_MODEL="gpt-4"
EOF

    echo -e "${GREEN}✓ Created configuration: $config_file${NC}"
    echo -e "${BLUE}  VM Name: $name${NC}"
    echo -e "${BLUE}  Port: $port${NC}"
    echo -e "${BLUE}  Workspace: $workspace_dir${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Edit configuration: ./manage.sh edit $name"
    echo "  2. Provision VM: ./provision.sh $name"
}

# List all configurations
list_configs() {
    echo -e "${BLUE}OpenClaw VM Configurations:${NC}"
    echo ""

    if [ ! "$(ls -A "$CONFIGS_DIR" 2>/dev/null)" ]; then
        echo "  No configurations found. Use './manage.sh scaffold <name>' to create one."
        return
    fi

    printf "%-20s %-8s %-15s %-10s\n" "NAME" "PORT" "VM STATUS" "CONFIG"
    printf "%-20s %-8s %-15s %-10s\n" "----" "----" "---------" "------"

    for config_file in "$CONFIGS_DIR"/*.env; do
        if [ -f "$config_file" ]; then
            local name=$(basename "$config_file" .env)
            local port=$(grep "OPENCLAW_PORT=" "$config_file" | cut -d'=' -f2 || echo "N/A")
            local vm_status="not created"

            # Check if VM exists
            if orb list 2>/dev/null | grep -q "^$name "; then
                vm_status=$(orb list 2>/dev/null | grep "^$name " | awk '{print $2}' || echo "unknown")
            fi

            # Check config validity
            local config_status="✓"
            if ! validate_config_silent "$name"; then
                config_status="✗"
            fi

            printf "%-20s %-8s %-15s %-10s\n" "$name" "$port" "$vm_status" "$config_status"
        fi
    done
}

# Edit configuration
edit_config() {
    local name="$1"
    local config_file="$CONFIGS_DIR/$name.env"

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}Error: Configuration '$name' not found${NC}"
        return 1
    fi

    local editor="${EDITOR:-nano}"
    "$editor" "$config_file"
    echo -e "${GREEN}✓ Configuration updated${NC}"
}

# Copy configuration
copy_config() {
    local source="$1"
    local dest="$2"
    local source_file="$CONFIGS_DIR/$source.env"
    local dest_file="$CONFIGS_DIR/$dest.env"

    if [ ! -f "$source_file" ]; then
        echo -e "${RED}Error: Source configuration '$source' not found${NC}"
        return 1
    fi

    if [ -f "$dest_file" ]; then
        echo -e "${RED}Error: Destination configuration '$dest' already exists${NC}"
        return 1
    fi

    cp "$source_file" "$dest_file"

    # Update the copied configuration
    local new_port=$(get_next_port)
    sed -i.bak \
        -e "s/VM_NAME=$source/VM_NAME=$dest/g" \
        -e "s/OPENCLAW_PORT=[0-9]*/OPENCLAW_PORT=$new_port/g" \
        -e "s/workspace-$source/workspace-$dest/g" \
        -e "s/# Generated: .*/# Generated: $(date) (copied from $source)/g" \
        "$dest_file"

    rm "$dest_file.bak"

    echo -e "${GREEN}✓ Copied '$source' to '$dest'${NC}"
    echo -e "${BLUE}  Updated port to: $new_port${NC}"
}

# Delete configuration
delete_config() {
    local name="$1"
    local config_file="$CONFIGS_DIR/$name.env"
    local workspace_dir="$WORKSPACES_DIR/workspace-$name"

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}Error: Configuration '$name' not found${NC}"
        return 1
    fi

    echo -e "${YELLOW}Warning: This will delete configuration '$name'${NC}"

    # Check if VM exists
    if orb list 2>/dev/null | grep -q "^$name "; then
        echo -e "${YELLOW}Warning: VM '$name' still exists and will need to be destroyed separately${NC}"
        echo "Use: orb delete $name"
    fi

    # Check if workspace exists
    if [ -d "$workspace_dir" ]; then
        echo -e "${YELLOW}Warning: Workspace directory exists: $workspace_dir${NC}"
        echo "Delete workspace too? (y/N)"
        read -r delete_workspace
        if [[ $delete_workspace =~ ^[Yy]$ ]]; then
            rm -rf "$workspace_dir"
            echo -e "${GREEN}✓ Deleted workspace directory${NC}"
        fi
    fi

    echo "Delete configuration file? (y/N)"
    read -r confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        rm "$config_file"
        echo -e "${GREEN}✓ Deleted configuration: $name${NC}"
    else
        echo "Cancelled"
    fi
}

# Validate configuration
validate_config_silent() {
    local name="$1"
    local config_file="$CONFIGS_DIR/$name.env"

    [ -f "$config_file" ] || return 1

    # Source the config and check required variables
    set +u  # Allow unset variables temporarily
    source "$config_file"
    local valid=true

    [ -n "${VM_NAME:-}" ] || valid=false
    [ -n "${OPENCLAW_PORT:-}" ] || valid=false
    [ -n "${WORKSPACE_DIR:-}" ] || valid=false

    set -u

    $valid
}

validate_config() {
    local name="$1"
    local config_file="$CONFIGS_DIR/$name.env"

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}Error: Configuration '$name' not found${NC}"
        return 1
    fi

    echo -e "${BLUE}Validating configuration: $name${NC}"

    # Source the config
    set +u  # Allow unset variables temporarily
    source "$config_file"

    # Check required variables
    local errors=0

    [ -n "${VM_NAME:-}" ] || { echo -e "${RED}✗ VM_NAME is required${NC}"; ((errors++)); }
    [ -n "${OPENCLAW_PORT:-}" ] || { echo -e "${RED}✗ OPENCLAW_PORT is required${NC}"; ((errors++)); }
    [ -n "${WORKSPACE_DIR:-}" ] || { echo -e "${RED}✗ WORKSPACE_DIR is required${NC}"; ((errors++)); }

    # Check port conflicts
    if [ -n "${OPENCLAW_PORT:-}" ]; then
        local port_conflicts=0
        for other_config in "$CONFIGS_DIR"/*.env; do
            if [ "$other_config" != "$config_file" ] && [ -f "$other_config" ]; then
                if grep -q "OPENCLAW_PORT=$OPENCLAW_PORT" "$other_config"; then
                    echo -e "${RED}✗ Port $OPENCLAW_PORT conflicts with $(basename "$other_config" .env)${NC}"
                    ((errors++))
                fi
            fi
        done
    fi

    set -u

    if [ $errors -eq 0 ]; then
        echo -e "${GREEN}✓ Configuration is valid${NC}"
        return 0
    else
        echo -e "${RED}Configuration has $errors error(s)${NC}"
        return 1
    fi
}

# Show status of configurations and VMs
show_status() {
    echo -e "${BLUE}=== OpenClaw VM Management Status ===${NC}"
    echo ""

    list_configs

    echo ""
    echo -e "${BLUE}Active VMs:${NC}"
    orb list 2>/dev/null | grep openclaw || echo "  No OpenClaw VMs running"

    echo ""
    echo -e "${BLUE}Port Usage:${NC}"
    for port in {18789..18799}; do
        if lsof -i ":$port" >/dev/null 2>&1; then
            echo "  Port $port: ✓ In use"
        fi
    done
}

# Create from template
create_from_template() {
    local template="$1"
    local name="$2"

    case "$template" in
        "telegram-bot")
            scaffold_config "$name"
            local config_file="$CONFIGS_DIR/$name.env"

            # Customize for Telegram bot
            sed -i.bak \
                -e 's/BOT_DESCRIPTION=".*"/BOT_DESCRIPTION="Telegram bot assistant"/g' \
                -e 's/ENABLE_WEB_BROWSING=false/ENABLE_WEB_BROWSING=true/g' \
                -e 's/AUTO_APPROVE_EMAIL=false/AUTO_APPROVE_EMAIL=true/g' \
                "$config_file"

            rm "$config_file.bak"
            echo -e "${GREEN}✓ Created Telegram bot configuration${NC}"
            echo -e "${YELLOW}Don't forget to set TELEGRAM_BOT_TOKEN_$(echo $name | tr '[:lower:]' '[:upper:]' | tr '-' '_')${NC}"
            ;;
        *)
            echo -e "${RED}Unknown template: $template${NC}"
            echo "Available templates: default, telegram-bot"
            return 1
            ;;
    esac
}

# Main command router
main() {
    case "${1:-}" in
        "scaffold")
            [ $# -eq 2 ] || { echo "Usage: $0 scaffold <name>"; exit 1; }
            scaffold_config "$2"
            ;;
        "list")
            list_configs
            ;;
        "edit")
            [ $# -eq 2 ] || { echo "Usage: $0 edit <name>"; exit 1; }
            edit_config "$2"
            ;;
        "copy")
            [ $# -eq 3 ] || { echo "Usage: $0 copy <source> <dest>"; exit 1; }
            copy_config "$2" "$3"
            ;;
        "delete")
            [ $# -eq 2 ] || { echo "Usage: $0 delete <name>"; exit 1; }
            delete_config "$2"
            ;;
        "validate")
            [ $# -eq 2 ] || { echo "Usage: $0 validate <name>"; exit 1; }
            validate_config "$2"
            ;;
        "template")
            [ $# -eq 3 ] || { echo "Usage: $0 template <template-name> <name>"; exit 1; }
            create_from_template "$2" "$3"
            ;;
        "status")
            show_status
            ;;
        "-h"|"--help"|"help"|*)
            usage
            ;;
    esac
}

main "$@"