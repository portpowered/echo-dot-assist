#!/bin/bash
# portos-echo's bridge beside hassmic (scripts/device/bridge.sh), run on the PC with its folder moved into a temporary
# one and stand-ins for what needs the Echo: runas (says how it was called, then runs the command), chown, and a bridge
# that is a shell script.  What is checked: nothing at all without the binary or the configuration; the start (group,
# session, private folder, an input that stays open and is not ours); the clean stop by the end of its input, and
# SIGTERM for a bridge that does not take it; the wait between restarts, doubling to its cap and short again after a
# good run; a second supervisor taking over from the first; and that main.sh and the bundles carry the script.
cd "$(dirname "$0")/../.."; Q=$(mktemp -d); fail=0
trap 'pkill -f "$Q/" 2>/dev/null; rm -rf "$Q"' EXIT
ok_() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; sed 's/^/     /' $Q/log $Q/runas.log 2>/dev/null; fail=1; fi; }

E=$Q/eb; P=$E/private; mkdir -p $Q/bin $Q/dev
sed "s#/data/local/echo-bridge#$E#g; s#/data/local/hassmic/boot.log#$Q/log#" scripts/device/bridge.sh > $Q/dev/bridge.sh
printf '#!/bin/sh\nexit 0\n' > $Q/bin/chown
# sleep: the waits between restarts are written down and cut short where FAKE_SLEEP names a file
cat > $Q/bin/sleep << EOF
#!/bin/sh
[ -z "\$FAKE_SLEEP" ] || { echo "\$1" >> "\$FAKE_SLEEP"; exec $(command -v sleep) 0.02; }
exec $(command -v sleep) "\$@"
EOF
cat > $Q/dev/runas << EOF
#!/bin/sh
echo "\$*" >> $Q/runas.log
shift 2; exec "\$@"
EOF
# The bridge: what it was started with and how, then by $Q/mode: reads its input to the end (as the real one stops),
# exits at once, or ignores the end of its input
cat > $Q/bridge << EOF
#!/bin/sh
read -r _ _ _ _ _ sid _ < /proc/\$\$/stat
[ "\$sid" = \$\$ ] && echo own >> $Q/session
[ -e /proc/\$\$/fd/3 ] && echo open >> $Q/fd3
readlink /proc/\$\$/fd/0 >> $Q/stdin
echo \$\$ >> $Q/starts
echo "said by the bridge"
case "\$(cat $Q/mode)" in
eof)  cat > /dev/null; echo \$\$ >> $Q/eof; exit 0;;
fail) [ "\$(wc -l < $Q/starts)" -lt "\$(cat $Q/until)" ] || rm -f $P/bridge.toml; exit 7;;
deaf) trap 'echo \$\$ >> $Q/term; exit 0' TERM; cat > /dev/null; while :; do $(command -v sleep) 0.1; done;;
esac
EOF
chmod 755 $Q/bin/* $Q/dev/runas $Q/bridge

B() { PATH=$Q/bin:$PATH sh $Q/dev/bridge.sh "$@"; }
S() { PATH=$Q/bin:$PATH exec sh $Q/dev/bridge.sh run < /dev/null >> $Q/log 2>&1; }      # with &: $! is the supervisor itself
fresh() { pkill -f "$Q/dev/bridge.sh" 2>/dev/null; pkill -f "$E/echo-bridge" 2>/dev/null; rm -rf $E $Q/log $Q/runas.log $Q/session $Q/fd3 $Q/stdin $Q/starts $Q/eof $Q/term $Q/sleeps; }
opted() { fresh; mkdir -p $P; chmod 777 $E $P; cp $Q/bridge $E/echo-bridge; echo x > $E/codex-app-server; chmod 777 $E/codex-app-server; echo '[echo]' > $P/bridge.toml; chmod 666 $P/bridge.toml; echo $1 > $Q/mode; }
until_() { i=0; until eval "$1" 2>/dev/null; do i=$((i + 1)); [ $i -lt 100 ] || return 1; sleep 0.1; done; }
lines() { wc -l < $1 2>/dev/null || echo 0; }

# --- not opted in: nothing happens
fresh; B run > $Q/out 2>&1; r=$?
[ $r = 0 ] && [ ! -s $Q/out ] && [ ! -e $Q/runas.log ] && [ ! -e $E ]; ok_ $? "no bridge folder: run ends at once, says nothing, starts nothing"
fresh; mkdir -p $P; cp $Q/bridge $E/echo-bridge; B run > $Q/out 2>&1; r=$?
[ $r = 0 ] && [ ! -s $Q/out ] && [ ! -e $Q/runas.log ] && [ "$(ls $P)" = "" ]; ok_ $? "the binary without a configuration: nothing, and nothing written into its folder"
fresh; mkdir -p $P; echo '[echo]' > $P/bridge.toml; B run > $Q/out 2>&1; r=$?
[ $r = 0 ] && [ ! -s $Q/out ] && [ ! -e $Q/runas.log ] && [ "$(ls $P)" = "bridge.toml" ]; ok_ $? "a configuration without the binary: nothing"
fresh; mkdir -p $P; echo '[echo]' > $P/bridge.toml; ln -s $Q/bridge $E/echo-bridge; B run > $Q/out 2>&1; r=$?
[ $r = 0 ] && [ ! -e $Q/runas.log ]; ok_ $? "the binary a link: not run"
fresh; B start > $Q/out 2>&1; [ $? = 0 ] && grep -q 'nothing to start' $Q/out && [ ! -e $Q/log ]; ok_ $? "start by hand without them: says so, starts nothing"
fresh; B stop > $Q/out 2>&1; [ $? = 0 ] && grep -q 'not running' $Q/out; ok_ $? "stop with nothing running"

# --- the start
opted eof; S & sup=$!
until_ '[ -s $Q/starts ]'; ok_ $? "with both there the bridge starts"
[ "$(cat $Q/runas.log)" = "root 3990,inet $E/echo-bridge --config $P/bridge.toml --trace $P/trace.jsonl" ]
ok_ $? "as root with group 3990 and inet, the configuration and the trace in its private folder"
[ "$(cat $Q/session)" = own ]; ok_ $? "in a session of its own"
[ "$(cat $Q/stdin)" = "$P/stdin" ] && [ -p $P/stdin ] && [ ! -e $Q/fd3 ]; ok_ $? "its input a FIFO, the writing end not handed to it"
[ "$(stat -c %a $P)" = 700 ] && [ "$(stat -c %a $P/bridge.toml)" = 600 ] && [ "$(stat -c %a $E)" = 755 ] && [ "$(stat -c %a $E/echo-bridge)" = 755 ] && [ "$(stat -c %a $E/codex-app-server)" = 755 ]
ok_ $? "folders and files adb left open to everyone: closed"
[ "$(stat -c %a $P/bridge.log)" = 600 ] && grep -q 'said by the bridge' $P/bridge.log && ! grep -q 'said by the bridge' $Q/log
ok_ $? "what the bridge says: a private file, not the boot log"
sleep 1.5; [ "$(lines $Q/starts)" = 1 ] && [ ! -e $Q/eof ] && kill -0 $(cat $P/bridge.pid); ok_ $? "its input stays open: still the first one after 1.5 s"

# --- the clean stop
B stop > $Q/out 2>&1; r=$?
[ $r = 0 ] && [ "$(cat $Q/eof)" = "$(cat $Q/starts)" ] && ! kill -0 $sup 2>/dev/null && grep -q 'stopped (its input closed, rc=0)' $Q/log
ok_ $? "stop: the bridge saw the end of its input and ended itself, the supervisor after it"
sleep 0.5; [ "$(lines $Q/starts)" = 1 ] && [ ! -e $P/bridge.pid ] && [ ! -e $P/supervisor.pid ]; ok_ $? "and it is not started again"

opted deaf; sed -i 's/^STOP_WAIT=10$/STOP_WAIT=1/' $Q/dev/bridge.sh
S & sup=$!
until_ '[ -s $Q/starts ]'; B stop > $Q/out 2>&1; r=$?
[ $r = 0 ] && [ "$(cat $Q/term)" = "$(cat $Q/starts)" ] && ! kill -0 $sup 2>/dev/null; ok_ $? "a bridge that ignores the end of its input: SIGTERM after the wait"

# --- a supervisor that is killed (the service stopped): its bridge ends by itself; the next one takes over
opted eof; S & sup=$!
until_ '[ -s $Q/starts ]'; { kill -KILL $sup; wait $sup; } 2> /dev/null; until_ '[ -s $Q/eof ]'; ok_ $? "the supervisor killed: the bridge sees the end of its input"
opted eof; S & sup=$!
until_ '[ -s $Q/starts ]'; S & sup2=$!
until_ '[ "$(lines $Q/starts)" = 2 ]' && [ "$(cat $Q/eof)" = "$(head -1 $Q/starts)" ] && ! kill -0 $sup 2>/dev/null && kill -0 $sup2
ok_ $? "a second supervisor: the first and its bridge end cleanly, then the second's starts"
[ "$(pgrep -f "$E/echo-bridge" | wc -l)" = 1 ]; ok_ $? "one bridge at a time"
B stop > /dev/null 2>&1

# --- the wait between restarts
opted fail; echo 10 > $Q/until
FAKE_SLEEP=$Q/sleeps B run < /dev/null >> $Q/log 2>&1; r=$?
[ "$(tr '\n' ' ' < $Q/sleeps)" = "3 6 12 24 48 96 192 300 300 300 " ]; ok_ $? "a bridge that exits at once: 3 s, doubled each time, 5 min at most ($(tr '\n' ' ' < $Q/sleeps))"
[ $r = 0 ] && [ "$(lines $Q/starts)" = 10 ] && grep -q 'exited rc=7 after [01] s, restart in 3 s' $Q/log && grep -q 'is gone: not started again' $Q/log
ok_ $? "each exit in the log with its status; the configuration taken away: not started again"
opted fail; echo 4 > $Q/until; sed -i 's/^GOOD_RUN=60$/GOOD_RUN=0/' $Q/dev/bridge.sh
FAKE_SLEEP=$Q/sleeps B run < /dev/null >> $Q/log 2>&1
[ "$(tr '\n' ' ' < $Q/sleeps)" = "3 3 3 3 " ]; ok_ $? "after a run that was long enough: 3 s again"
sed -i 's/^GOOD_RUN=0$/GOOD_RUN=60/' $Q/dev/bridge.sh
opted fail; echo 99 > $Q/until
FAKE_SLEEP= S & sup=$!
until_ '[ -s $Q/starts ]'; sleep 0.3; B stop > $Q/out 2>&1; r=$?
[ $r = 0 ] && ! kill -0 $sup 2>/dev/null && [ "$(lines $Q/starts)" = 1 ]; ok_ $? "stop during the wait: no second start"

# --- carried by the boot script, the update bundle and the installers; parses as every script that goes on the Echo
grep -q '\[ -f \$D/bridge.sh \] && sh \$D/bridge.sh run < /dev/null >> \$LOG 2>&1 &' scripts/system/main.sh; ok_ $? "main.sh satellite starts it where the script is there"
for f in scripts/bundle.sh scripts/install-system.sh scripts/install-boot.sh; do grep -q 'scripts/device/bridge.sh' $f || { echo "$f" > $Q/log; false; break; }; done
ok_ $? "in the update bundle and both installers"
sh -n scripts/device/bridge.sh && sh -n scripts/system/main.sh; ok_ $? "both parse"
exit $fail
