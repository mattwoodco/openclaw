#!/bin/bash
set -euo pipefail

# OpenClaw Zero-Approval Verification Script
# This script verifies that a VM is configured for zero-approval operation

VM_NAME="${1:-}"
if [[ -z "$VM_NAME" ]]; then
    echo "Usage: $0 <vm-name>"
    echo "Example: $0 mo"
    exit 1
fi

echo "Verifying zero-approval configuration for VM: $VM_NAME"

# Check if VM exists
if ! orb list | grep -q "^$VM_NAME\s"; then
    echo "❌ VM '$VM_NAME' does not exist"
    exit 1
fi

# Check if VM is running
if ! orb list | grep "^$VM_NAME\s" | grep -q "running"; then
    echo "❌ VM '$VM_NAME' is not running"
    exit 1
fi

ISSUES_FOUND=0

# Verify approval configuration
echo "  Checking approval bypass configuration..."

EXEC_APPROVALS=$(orb -m "$VM_NAME" -u ocagent bash -c "
    openclaw config get approvals.exec.enabled 2>/dev/null || echo 'not_set'
" 2>/dev/null || echo "error")

if [[ "$EXEC_APPROVALS" == "false" ]]; then
    echo "  ✅ Exec approvals disabled"
else
    echo "  ❌ Exec approvals not properly disabled (current: $EXEC_APPROVALS)"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

# Verify allowlist configuration
echo "  Checking allowlist configuration..."

ALLOWLIST_COUNT=$(orb -m "$VM_NAME" -u ocagent bash -c "
    openclaw approvals allowlist list 2>/dev/null | wc -l || echo '0'
" 2>/dev/null || echo "0")

if [[ "$ALLOWLIST_COUNT" -gt 0 ]]; then
    echo "  ✅ Allowlist configured ($ALLOWLIST_COUNT entries)"

    # Check for wildcard pattern
    WILDCARD_PRESENT=$(orb -m "$VM_NAME" -u ocagent bash -c "
        openclaw approvals allowlist list 2>/dev/null | grep -c '^\\*\$' || echo '0'
    " 2>/dev/null || echo "0")

    if [[ "$WILDCARD_PRESENT" -gt 0 ]]; then
        echo "  ✅ Wildcard allowlist entry present"
    else
        echo "  ⚠️  Wildcard allowlist entry not found"
    fi
else
    echo "  ❌ Allowlist not configured or empty"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

# Test actual command execution (basic test)
echo "  Testing command execution without approval..."

TEST_RESULT=$(orb -m "$VM_NAME" -u ocagent bash -c "
    timeout 10s bash -c 'echo test_command_execution' 2>/dev/null || echo 'timeout_or_approval_required'
" 2>/dev/null || echo "error")

if [[ "$TEST_RESULT" == "test_command_execution" ]]; then
    echo "  ✅ Command execution works without approval"
else
    echo "  ❌ Command execution failed or required approval (result: $TEST_RESULT)"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

# Check OpenClaw service status
echo "  Checking OpenClaw service status..."

SERVICE_STATUS=$(orb -m "$VM_NAME" -u root bash -c "
    systemctl is-active openclaw 2>/dev/null || echo 'inactive'
" 2>/dev/null || echo "error")

if [[ "$SERVICE_STATUS" == "active" ]]; then
    echo "  ✅ OpenClaw service is active"
else
    echo "  ❌ OpenClaw service is not active (status: $SERVICE_STATUS)"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

# Final assessment
echo ""
if [[ $ISSUES_FOUND -eq 0 ]]; then
    echo "✅ Zero-approval verification PASSED for VM: $VM_NAME"
    echo "   All systems configured for approval-free operation"
    exit 0
else
    echo "❌ Zero-approval verification FAILED for VM: $VM_NAME"
    echo "   $ISSUES_FOUND issue(s) found that may require manual approval"
    exit 1
fi