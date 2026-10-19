# Opens the shell (centre "Open" button), focuses the terminal and runs a few commands in the real `db` container.
# Coordinates assume the 1440×900 window at {240, 60} that capture.sh sets.
"$CLICK" 1073 798; sleep 3; "$CLICK" 1040 700; sleep 0.5
for c in "psql -U acdemo -c 'select count(*) as tables from pg_tables;'" "ls /var/lib/postgresql/data | head -6" \
    "ps -o pid,user,args | head -8"; do
    osascript -e "tell application \"System Events\" to keystroke \"$c\"" -e 'tell application "System Events" to key code 36'
    sleep 1.2
done
sleep 1
