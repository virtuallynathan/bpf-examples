#!/bin/bash

set -e

# Ensure paths are absolute or correctly relative from script's execution path
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PPING_DIR="/app/pping"
PPING_EXEC_NAME="pping" # Name of the executable
PPING_PATH="$PPING_DIR/$PPING_EXEC_NAME"

# Temporary files in the tests directory
TMP_NO_AGG="$SCRIPT_DIR/output_no_agg.txt"
TMP_AGG="$SCRIPT_DIR/output_agg.txt"
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

echo "Starting JSONL tests..."
echo "Temporary files will be: $TMP_NO_AGG, $TMP_AGG"

# Cleanup function
cleanup() {
    echo "Cleaning up temporary files..."
    rm -f "$TMP_NO_AGG" "$TMP_AGG"
    rm -f "$SCRIPT_DIR/lines_no_agg.tmp" "$SCRIPT_DIR/lines_agg.tmp" # Ensure these are also cleaned
}
trap cleanup EXIT

# --- Scenario 1: Individual Events ---
echo "Running Scenario 1: Individual Events (no aggregation)..."
# Run pping for 2 seconds. -c 0 disables map cleanup.
# Send to background and kill after a short period to collect some output.
# Execute pping from its directory to ensure it finds pping_kern.o
(cd "$PPING_DIR" && sudo "./$PPING_EXEC_NAME" -i lo --format jsonl -c 0 > "$TMP_NO_AGG") &
PPING_PID=$!
sleep 2
# Check if process exists before killing
if ps -p $PPING_PID > /dev/null; then
   sudo kill $PPING_PID || true # allow kill to fail if process already exited gracefully
else
   echo "Scenario 1: pping process $PPING_PID already exited."
fi
wait $PPING_PID || true # Wait for the process to be reaped

echo "Validating $TMP_NO_AGG..."
if [ ! -s "$TMP_NO_AGG" ]; then
    echo "Warning: $TMP_NO_AGG is empty. Basic pping run might have issues or no events generated on 'lo' quickly."
fi

FIRST_CHAR_NO_AGG=$(head -c 1 "$TMP_NO_AGG" 2>/dev/null || true)
if [ "$FIRST_CHAR_NO_AGG" == "[" ]; then
    echo "Error: $TMP_NO_AGG appears to be a JSON array, not JSONL."
    TEST_FAILED=1
fi

LINE_COUNT_NO_AGG=0
# Use a temporary file for lines to avoid issues with process substitution and loops
grep -v '^$' "$TMP_NO_AGG" > "$SCRIPT_DIR/lines_no_agg.tmp" || true # Ensure grep doesn't fail if file is empty
while IFS= read -r line; do
    if [ -z "$line" ]; then # Skip genuinely empty lines if any passed grep
        continue
    fi
    LINE_COUNT_NO_AGG=$((LINE_COUNT_NO_AGG + 1))
    if ! echo "$line" | jq -e . > /dev/null; then
        echo "Invalid JSON line in $TMP_NO_AGG (line $LINE_COUNT_NO_AGG): $line"
        TEST_FAILED=1
        break
    fi
done < "$SCRIPT_DIR/lines_no_agg.tmp"
rm -f "$SCRIPT_DIR/lines_no_agg.tmp"

if [ "$TEST_FAILED" -eq 0 ]; then
    echo "Scenario 1: JSONL (no aggregation) basic validation passed ($LINE_COUNT_NO_AGG lines processed)."
else
    echo "Scenario 1: JSONL (no aggregation) basic validation FAILED."
fi
echo "--- End of Scenario 1 ---"
echo

# --- Scenario 2: Aggregated Events ---
# Reset TEST_FAILED for this scenario if needed, or let it persist
# For now, let it persist: if scenario 1 fails, the whole test fails.
# If you want independent scenarios, reset TEST_FAILED=0 here.

echo "Running Scenario 2: Aggregated Events..."
# Run pping for 3 seconds with 1s aggregation.
(cd "$PPING_DIR" && sudo "./$PPING_EXEC_NAME" -i lo --format jsonl -a 1 -c 0 > "$TMP_AGG") &
PPING_PID=$!
sleep 3 # Allow for at least 2 aggregation intervals + metadata
if ps -p $PPING_PID > /dev/null; then
   sudo kill $PPING_PID || true
else
   echo "Scenario 2: pping process $PPING_PID already exited."
fi
wait $PPING_PID || true

echo "Validating $TMP_AGG..."
if [ ! -s "$TMP_AGG" ]; then
    echo "Warning: $TMP_AGG is empty. Aggregated pping run might have issues or no events generated."
fi

FIRST_CHAR_AGG=$(head -c 1 "$TMP_AGG" 2>/dev/null || true)
if [ "$FIRST_CHAR_AGG" == "[" ]; then
    echo "Error: $TMP_AGG appears to be a JSON array, not JSONL."
    TEST_FAILED=1
fi

LINE_COUNT_AGG=0
HAS_AGG_METADATA=0
HAS_AGG_STATS=0
HAS_GLOBAL_COUNTERS=0

grep -v '^$' "$TMP_AGG" > "$SCRIPT_DIR/lines_agg.tmp" || true # Ensure grep doesn't fail if file is empty
while IFS= read -r line; do
    if [ -z "$line" ]; then # Skip genuinely empty lines
        continue
    fi
    LINE_COUNT_AGG=$((LINE_COUNT_AGG + 1))
    if ! echo "$line" | jq -e . > /dev/null; then
        echo "Invalid JSON line in $TMP_AGG (line $LINE_COUNT_AGG): $line"
        TEST_FAILED=1
        break
    fi
    if echo "$line" | jq -e '.aggregation_interval_ns' > /dev/null; then
        HAS_AGG_METADATA=1
    elif echo "$line" | jq -e '.ip_prefix and .rx_stats and .tx_stats' > /dev/null; then
        HAS_AGG_STATS=1
    elif echo "$line" | jq -e '.protocol_counters and .ecn_counters' > /dev/null; then
        HAS_GLOBAL_COUNTERS=1
    fi
done < "$SCRIPT_DIR/lines_agg.tmp"
rm -f "$SCRIPT_DIR/lines_agg.tmp"

if [ "$HAS_AGG_METADATA" -eq 0 ] && [ "$LINE_COUNT_AGG" -gt 0 ]; then # Only warn if file is not empty
    echo "Warning: Did not find aggregation metadata line in $TMP_AGG."
fi
# For aggregated output, we definitely expect some data if pping ran correctly.
# If LINE_COUNT_AGG is 0, something is wrong with pping itself.
if [ "$LINE_COUNT_AGG" -gt 0 ] && [ "$HAS_AGG_METADATA" -eq 0 ] && [ "$HAS_AGG_STATS" -eq 0 ] && [ "$HAS_GLOBAL_COUNTERS" -eq 0 ]; then
    echo "Error: No recognizable pping JSONL output types (metadata, stats, counters) found in $TMP_AGG, though file is not empty."
    TEST_FAILED=1
fi


if [ "$TEST_FAILED" -eq 0 ]; then
    echo "Scenario 2: JSONL (aggregated) basic validation passed ($LINE_COUNT_AGG lines processed)."
    echo "Found aggregation metadata: $HAS_AGG_METADATA"
    echo "Found aggregated stats lines: $HAS_AGG_STATS"
    echo "Found global counters lines: $HAS_GLOBAL_COUNTERS"
else
    echo "Scenario 2: JSONL (aggregated) basic validation FAILED."
fi
echo "--- End of Scenario 2 ---"
echo

if [ "$TEST_FAILED" -eq 0 ]; then
    echo "All JSONL tests passed!"
    exit 0
else
    echo "One or more JSONL tests FAILED."
    exit 1
fi
