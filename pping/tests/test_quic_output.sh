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
    # Do not exit yet, proceed to Scenario 2
    # exit 1 
fi

# --- Scenario 2: QUIC Tracking with Aggregation Enabled ---
echo
echo "Running Scenario 2: QUIC Tracking with Aggregation Enabled..."
TMP_QUIC_AGG_OUT="$SCRIPT_DIR/output_quic_agg.txt"
TMP_QUIC_AGG_STDERR="$SCRIPT_DIR/stderr_quic_agg.txt"
# Add these to cleanup
trap 'rm -f "$TMP_QUIC_OUT" "$TMP_QUIC_STDERR" "$SCRIPT_DIR/lines_quic.tmp" "$TMP_QUIC_AGG_OUT" "$TMP_QUIC_AGG_STDERR" "$SCRIPT_DIR/lines_quic_agg.tmp"; echo "Cleaning up all temporary files...";' EXIT


# Run pping for 3 seconds with --quic and 1s aggregation. -c 0 disables map cleanup.
(cd "$PPING_DIR" && sudo "./$PPING_EXEC_NAME" -i lo --quic -a 1 --format jsonl -c 0 > "$TMP_QUIC_AGG_OUT" 2> "$TMP_QUIC_AGG_STDERR") &
PPING_PID=$!
sleep 3 # Allow for at least 2 aggregation intervals + metadata
if ps -p $PPING_PID > /dev/null; then
   sudo kill $PPING_PID || true
else
   echo "Scenario 2: pping process $PPING_PID already exited."
fi
wait $PPING_PID || true

echo "Validating Scenario 2 stderr for QUIC tracking and aggregation messages ($TMP_QUIC_AGG_STDERR)..."
SCENARIO2_STDERR_OK=1
if ! grep -q "tracking .*QUIC" "$TMP_QUIC_AGG_STDERR"; then
    echo "Scenario 2 Stderr check FAILED: Did not find 'tracking QUIC' message."
    SCENARIO2_STDERR_OK=0
fi
if ! grep -q "Aggregating RTTs" "$TMP_QUIC_AGG_STDERR"; then # Check for a generic aggregation message
    echo "Scenario 2 Stderr check FAILED: Did not find aggregation message."
    SCENARIO2_STDERR_OK=0
fi

if [ "$SCENARIO2_STDERR_OK" -eq 1 ]; then
    echo "Scenario 2 Stderr checks PASSED."
else
    cat "$TMP_QUIC_AGG_STDERR"
    TEST_FAILED=1
fi


echo "Validating Scenario 2 JSONL output ($TMP_QUIC_AGG_OUT)..."
if [ ! -s "$TMP_QUIC_AGG_OUT" ]; then
    echo "Warning: $TMP_QUIC_AGG_OUT is empty. Aggregated QUIC pping run might have issues or no events generated."
    # This is not a failure for this smoke test if stderr checks passed for startup.
fi

FIRST_CHAR_QUIC_AGG_OUT=$(head -c 1 "$TMP_QUIC_AGG_OUT" 2>/dev/null || true)
if [ -s "$TMP_QUIC_AGG_OUT" ] && [ "$FIRST_CHAR_QUIC_AGG_OUT" == "[" ]; then
    echo "Error: $TMP_QUIC_AGG_OUT appears to be a JSON array, not JSONL."
    TEST_FAILED=1
fi

LINE_COUNT_QUIC_AGG=0
HAS_AGG_METADATA=0
HAS_AGG_STATS=0      # For subnet stats
HAS_GLOBAL_COUNTERS=0 # For global counters typically printed with aggregation
HAS_GLOBAL_QUIC_FIELDS=0 # Specifically for quic_pkts and quic_bytes in global counters

# Use a temporary file for lines to avoid issues with process substitution and loops
grep -v '^$' "$TMP_QUIC_AGG_OUT" > "$SCRIPT_DIR/lines_quic_agg.tmp" || true

if [ -s "$SCRIPT_DIR/lines_quic_agg.tmp" ]; then
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            continue
        fi
        LINE_COUNT_QUIC_AGG=$((LINE_COUNT_QUIC_AGG + 1))
        if ! echo "$line" | jq -e . > /dev/null; then
            echo "Invalid JSON line in $TMP_QUIC_AGG_OUT (line $LINE_COUNT_QUIC_AGG): $line"
            TEST_FAILED=1
            break
        fi
        # Check for different types of expected aggregation lines
        if echo "$line" | jq -e '.aggregation_interval_ns' > /dev/null; then
            HAS_AGG_METADATA=1
        elif echo "$line" | jq -e '.ip_prefix and .rx_stats and .tx_stats' > /dev/null; then
            HAS_AGG_STATS=1
            # Opportunistically check for quic_spin1_packets, but its absence is not a failure
            if echo "$line" | jq -e '.quic_spin1_packets' > /dev/null; then
                echo "Found 'quic_spin1_packets' field in an aggregated stats line."
            fi
        elif echo "$line" | jq -e '.protocol_counters and .ecn_counters' > /dev/null; then # This identifies a global counters line
            HAS_GLOBAL_COUNTERS=1
            # Now check for the presence of quic_pkts and quic_bytes within .protocol_counters
            if echo "$line" | jq -e '.protocol_counters | has("quic_pkts") and has("quic_bytes")' > /dev/null; then
                HAS_GLOBAL_QUIC_FIELDS=1
                echo "Found 'quic_pkts' and 'quic_bytes' in global counters."
            else
                # If this is a global counters line but doesn't have the QUIC fields, it's an error
                # (assuming --quic means they should always be present, even if zero)
                echo "Error: Global counters line identified, but 'quic_pkts' or 'quic_bytes' are missing from .protocol_counters."
                echo "Line content: $line"
                TEST_FAILED=1
            fi
        fi
    done < "$SCRIPT_DIR/lines_quic_agg.tmp"
fi
rm -f "$SCRIPT_DIR/lines_quic_agg.tmp"

if [ "$TEST_FAILED" -eq 0 ]; then
    echo "Scenario 2: JSONL (QUIC with aggregation) basic validation passed ($LINE_COUNT_QUIC_AGG lines processed)."
    if [ "$LINE_COUNT_QUIC_AGG" -gt 0 ]; then # Only print these if there was some output
        echo "Found aggregation metadata: $HAS_AGG_METADATA"
        echo "Found aggregated stats lines: $HAS_AGG_STATS"
        echo "Found global counters lines: $HAS_GLOBAL_COUNTERS"
        if [ "$HAS_GLOBAL_COUNTERS" -gt 0 ] && [ "$HAS_GLOBAL_QUIC_FIELDS" -eq 0 ]; then
            echo "Error: Global counters lines were found, but they did not contain the expected 'quic_pkts' and 'quic_bytes' fields."
            # TEST_FAILED might have already been set by the inner check, but ensure it is.
            TEST_FAILED=1
        elif [ "$HAS_GLOBAL_COUNTERS" -gt 0 ] && [ "$HAS_GLOBAL_QUIC_FIELDS" -eq 1 ]; then
            echo "Global QUIC counter fields ('quic_pkts', 'quic_bytes') successfully found in global counters output."
        fi

        if [ "$HAS_AGG_METADATA" -eq 0 ] && [ "$HAS_AGG_STATS" -eq 0 ] && [ "$HAS_GLOBAL_COUNTERS" -eq 0 ]; then
             echo "Warning: No standard aggregation output lines (metadata, stats, counters) found, though output file was not empty."
        fi
    fi
else
    echo "Scenario 2: JSONL (QUIC with aggregation) basic validation FAILED."
fi
echo "--- End of Scenario 2 ---"
echo


# Final Exit Status
if [ "$TEST_FAILED" -eq 0 ]; then
    echo "All QUIC output tests passed!"
    exit 0
else
    echo "One or more QUIC output tests FAILED."
    exit 1
fi
