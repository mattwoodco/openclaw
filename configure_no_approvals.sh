#!/bin/bash
set -euo pipefail

# OpenClaw Zero-Approval Configuration Script
# This script configures an existing OpenClaw VM to bypass all approval prompts

VM_NAME="${1:-}"
if [[ -z "$VM_NAME" ]]; then
    echo "Usage: $0 <vm-name>"
    echo "Example: $0 mo"
    exit 1
fi

echo "Configuring zero-approval mode for VM: $VM_NAME"

# Check if VM exists
if ! orb list | grep -q "^$VM_NAME\s"; then
    echo "Error: VM '$VM_NAME' does not exist"
    exit 1
fi

# Configure approval bypass
echo "  Disabling exec approvals..."
orb -m "$VM_NAME" -u ocagent bash -c "
    set -euo pipefail

    # Disable exec approvals completely
    openclaw config set approvals.exec.enabled false 2>/dev/null || true

    # Clear existing allowlist and add comprehensive patterns
    openclaw approvals allowlist clear 2>/dev/null || true

    # Add wildcard and specific allowlist patterns
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

    echo 'Zero-approval configuration applied successfully'
" || {
    echo "Error: Failed to configure approval bypass for VM '$VM_NAME'"
    exit 1
}

echo "✅ Zero-approval mode configured for VM: $VM_NAME"
echo "   All commands will now execute without approval prompts"