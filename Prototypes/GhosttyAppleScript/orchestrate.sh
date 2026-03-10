#!/bin/bash
# orchestrate.sh — End-to-end prototype for Ghostty orchestration via AppleScript.
# Demonstrates: open Ghostty, send a command, wait, list windows.
#
# Prerequisites:
#   - Ghostty installed and in PATH
#   - Accessibility permissions granted to Terminal.app / osascript
#
# Usage: ./orchestrate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Ghostty AppleScript Orchestration Prototype ==="
echo ""

# Step 1: Check if Ghostty is running
if pgrep -x ghostty > /dev/null 2>&1; then
    echo "[OK] Ghostty is running"
else
    echo "[INFO] Ghostty not running — attempting to launch..."
    open -a Ghostty
    sleep 2
fi

# Step 2: List windows
echo ""
echo "--- Listing Ghostty windows ---"
osascript "$SCRIPT_DIR/list-windows.scpt" 2>&1 || echo "[WARN] list-windows failed (accessibility?)"

# Step 3: Send a test command
echo ""
echo "--- Sending test command ---"
osascript "$SCRIPT_DIR/send-keys.scpt" "echo 'Hello from Cosmodrome orchestration'" 2>&1 || echo "[WARN] send-keys failed"

sleep 1

# Step 4: Try to read content
echo ""
echo "--- Attempting to read terminal content ---"
osascript "$SCRIPT_DIR/read-content.scpt" 2>&1 || echo "[WARN] read-content failed (expected — accessibility limitations)"

echo ""
echo "=== Done ==="
echo "Note: Terminal content reading is limited by macOS accessibility APIs."
echo "For deeper integration, consider using Ghostty's built-in IPC when available."
