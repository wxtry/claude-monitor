#!/bin/bash
# lock-awake.sh — Lock screen while keeping Mac awake, restore on unlock

LOG="/tmp/lock-awake.log"
echo "$(date) START" > "$LOG"

# Prevent system idle sleep
caffeinate -is &
CAFE_PID=$!
echo "$(date) caffeinate PID=$CAFE_PID" >> "$LOG"

# Lock screen
sleep 0.5
osascript -e 'tell application "System Events" to keystroke "q" using {command down, control down}'
echo "$(date) lock command sent" >> "$LOG"

# Wait for lock to engage
sleep 5
ioreg -n Root -d1 -w 0 | grep "CGSSessionScreenIsLocked" >> "$LOG" 2>&1
echo "$(date) start polling..." >> "$LOG"

# Poll until unlocked (value is "CGSSessionScreenIsLocked"=Yes)
COUNT=0
while ioreg -n Root -d1 -w 0 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'; do
    COUNT=$((COUNT+1))
    sleep 2
done
echo "$(date) unlocked after $COUNT polls" >> "$LOG"

# Restore normal sleep
kill "$CAFE_PID" 2>/dev/null
wait "$CAFE_PID" 2>/dev/null || true
echo "$(date) caffeinate killed, sending notification..." >> "$LOG"

osascript -e 'display notification "Normal sleep restored" with title "Lock Awake" subtitle "Caffeinate stopped"' >> "$LOG" 2>&1
echo "$(date) DONE" >> "$LOG"
