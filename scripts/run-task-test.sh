#!/bin/bash
# run-task-test.sh — submit a task to the running macOS agent and watch outcome
# Usage: ./scripts/run-task-test.sh "open safari and go to gmail.com"
#        ./scripts/run-task-test.sh  (uses default task)

TASK="${1:-In Safari, click the address bar, type gmail.com, and press Return to navigate there.}"
TIMEOUT=120
POLL=2

echo "=== macOS Agent Task Test ==="
echo "Task: $TASK"
echo ""

if ! pgrep -x MacOSAgentV0 > /dev/null; then
    echo "ERROR: MacOSAgentV0 is not running."
    exit 1
fi

# Submit task — the composer TextField is nested inside a group in the window
SUBMIT_RESULT=$(osascript 2>&1 << ASEOF
tell application "MacOSAgentV0" to activate
delay 0.5
tell application "System Events"
    tell process "MacOSAgentV0"
        tell window "macOS Agent v0"
            -- The text field is one level deep inside a group
            set tf to first text field of first group
            set focused of tf to true
            delay 0.2
            keystroke "a" using command down
            delay 0.1
            set value of tf to "$TASK"
            delay 0.3
            keystroke return
            return "submitted"
        end tell
    end tell
end tell
ASEOF
)

if [[ "$SUBMIT_RESULT" != "submitted" ]]; then
    echo "ERROR submitting task: $SUBMIT_RESULT"
    exit 1
fi

echo "Submitted at $(date +%H:%M:%S). Watching for outcome..."
echo ""

START=$(date +%s)
LAST_SNAPSHOT=""

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))

    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo ""
        echo "TIMEOUT after ${TIMEOUT}s"
        exit 2
    fi

    SNAPSHOT=$(osascript 2>/dev/null << ASEOF2
tell application "System Events"
    tell process "MacOSAgentV0"
        tell window "macOS Agent v0"
            set allText to {}
            repeat with e in (every static text)
                try
                    set v to value of e as string
                    if length of v > 3 then set allText to allText & {v}
                end try
            end repeat
            return allText
        end tell
    end tell
end tell
ASEOF2
)

    if [ "$SNAPSHOT" != "$LAST_SNAPSHOT" ]; then
        LAST_SNAPSHOT="$SNAPSHOT"
        INTERESTING=$(echo "$SNAPSHOT" | tr ',' '\n' | grep -iE "finish|fail|error|complete|navigat|gmail|ready|running|✅|❌|recover|budget" | tail -4)
        [ -n "$INTERESTING" ] && echo "[${ELAPSED}s] $INTERESTING"
    fi

    if echo "$SNAPSHOT" | grep -qi "finished\|task complete\|gmail"; then
        echo ""
        echo "✅ PASS — completed in ${ELAPSED}s"
        exit 0
    fi
    if echo "$SNAPSHOT" | grep -qi "failed\|budget exhausted\|run failed"; then
        echo ""
        echo "❌ FAIL after ${ELAPSED}s"
        echo "$SNAPSHOT" | tr ',' '\n' | tail -6
        exit 3
    fi

    sleep $POLL
done
