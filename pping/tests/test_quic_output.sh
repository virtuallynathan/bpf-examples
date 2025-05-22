#!/bin/bash
#
# test_quic_output.sh - Smoke test for pping's QUIC functionality.
#
# This test primarily verifies that pping can be started with the --quic
# option and produces valid JSONL output. It also checks if the stderr
# log correctly indicates that QUIC is being tracked.
#
# It does NOT simulate actual QUIC traffic or specific spin bit sequences,
# so it doesn't test the eBPF RTT calculation logic in detail. It's a
# user-space focused smoke test.
#
# Requirements:
# - pping and pping_kern.o must be built.
# - jq must be installed.
# - The script must be run with sudo or as root for pping execution.

set -e

# Ensure paths are absolute or correctly relative from script's execution path
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PPING_DIR="/app/pping" # Assuming /app is the root of the repository in the test environment
PPING_EXEC_NAME="pping" # Name of the executable
PPING_PATH="$PPING_DIR/$PPING_EXEC_NAME"

# Temporary files in the tests directory
TMP_QUIC_OUT="$SCRIPT_DIR/output_quic.txt"
TMP_QUIC_STDERR="$SCRIPT_DIR/stderr_quic.txt"
TEST_FAILED=0

# Check if pping executable exists
if [ ! -f "$PPING_PATH" ]; then
    echo "Error: pping executable not found at $PPING_PATH"
    exit 1
fi

# Check if pping_kern.o exists
if [ ! -f "$PPING_DIR/pping_kern.o" ]; then
    echo "Error: pping_kern.o not found in $PPING_DIR. Build pping first."
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq."
    exit 1
fi

echo "Starting QUIC output tests..."
echo "Temporary files will be: $TMP_QUIC_OUT, $TMP_QUIC_STDERR"

# Cleanup function
cleanup() {
    echo "Cleaning up temporary files..."
    rm -f "$TMP_QUIC_OUT" "$TMP_QUIC_STDERR"
    rm -f "$SCRIPT_DIR/lines_quic.tmp" # Ensure these are also cleaned
}
trap cleanup EXIT

# --- Scenario: QUIC Tracking Enabled ---
echo "Running Scenario: QUIC Tracking Enabled..."
# Run pping for 2 seconds with --quic. -c 0 disables map cleanup.
# Capture stdout to TMP_QUIC_OUT and stderr to TMP_QUIC_STDERR
(cd "$PPING_DIR" && sudo "./$PPING_EXEC_NAME" -i lo --quic --format jsonl -c 0 > "$TMP_QUIC_OUT" 2> "$TMP_QUIC_STDERR") &
PPING_PID=$!
sleep 2
# Check if process exists before killing
if ps -p $PPING_PID > /dev/null; then
   sudo kill $PPING_PID || true # allow kill to fail if process already exited gracefully
else
   echo "Scenario: pping process $PPING_PID already exited."
fi
wait $PPING_PID || true # Wait for the process to be reaped

echo "Validating stderr for QUIC tracking ($TMP_QUIC_STDERR)..."
if grep -q "Starting ePPing.*tracking .*QUIC" "$TMP_QUIC_STDERR"; then
    echo "Stderr check PASSED: Found 'tracking QUIC' message."
else
    echo "Stderr check FAILED: Did not find 'tracking QUIC' message."
    cat "$TMP_QUIC_STDERR"
    TEST_FAILED=1
fi

echo "Validating JSONL output ($TMP_QUIC_OUT)..."
if [ ! -s "$TMP_QUIC_OUT" ]; then
    echo "Warning: $TMP_QUIC_OUT is empty. No RTT/flow events were generated on 'lo'."
    # This is not a failure for this smoke test, as event generation is opportunistic.
fi

FIRST_CHAR_QUIC_OUT=$(head -c 1 "$TMP_QUIC_OUT" 2>/dev/null || true)
if [ -s "$TMP_QUIC_OUT" ] && [ "$FIRST_CHAR_QUIC_OUT" == "[" ]; then # Only check if file is not empty
    echo "Error: $TMP_QUIC_OUT appears to be a JSON array, not JSONL."
    TEST_FAILED=1
fi

LINE_COUNT_QUIC=0
HAS_QUIC_PROTOCOL_LINE=0
# Use a temporary file for lines to avoid issues with process substitution and loops
grep -v '^$' "$TMP_QUIC_OUT" > "$SCRIPT_DIR/lines_quic.tmp" || true # Ensure grep doesn't fail if file is empty

# Only proceed if lines_quic.tmp is not empty
if [ -s "$SCRIPT_DIR/lines_quic.tmp" ]; then
    while IFS= read -r line; do
        if [ -z "$line" ]; then # Skip genuinely empty lines if any passed grep
            continue
        fi
        LINE_COUNT_QUIC=$((LINE_COUNT_QUIC + 1))
        if ! echo "$line" | jq -e . > /dev/null; then
            echo "Invalid JSON line in $TMP_QUIC_OUT (line $LINE_COUNT_QUIC): $line"
            TEST_FAILED=1
            break
        fi
        # Check if this line is an RTT or Flow event and has protocol: "QUIC"
        if echo "$line" | jq -e '.protocol == "QUIC"' > /dev/null; then
            HAS_QUIC_PROTOCOL_LINE=1
        fi
    done < "$SCRIPT_DIR/lines_quic.tmp"
fi
rm -f "$SCRIPT_DIR/lines_quic.tmp"

if [ "$TEST_FAILED" -eq 0 ]; then
    echo "Scenario: JSONL (QUIC tracking) basic validation passed ($LINE_COUNT_QUIC lines processed)."
    if [ "$LINE_COUNT_QUIC" -gt 0 ] && [ "$HAS_QUIC_PROTOCOL_LINE" -eq 0 ]; then
        echo "Note: No RTT/flow events with 'protocol: QUIC' found in output. This is acceptable if no QUIC traffic occurred on 'lo'."
    elif [ "$HAS_QUIC_PROTOCOL_LINE" -eq 1 ]; then
        echo "Found at least one event with 'protocol: QUIC'."
    fi
else
    echo "Scenario: JSONL (QUIC tracking) basic validation FAILED."
fi
echo "--- End of Scenario ---"
echo

if [ "$TEST_FAILED" -eq 0 ]; then
    echo "QUIC output smoke test passed!"
    exit 0
else
    echo "QUIC output smoke test FAILED."
    exit 1
fi
