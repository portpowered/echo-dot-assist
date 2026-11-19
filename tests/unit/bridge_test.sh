#!/bin/bash
# portos-echo's bridge beside hassmic (scripts/device/bridge.sh), run on the PC with its folders moved into a temporary
# one and stand-ins for what needs the Echo: runas (says how it was called, then runs the command), ps (the Echo's
# `ps -A -o NAME`), a bridge that is a shell script, and the launcher portos-echo's installer writes (launch.sh below is
# its text, from scripts/echo-install.sh there), with the installer's start and stop done the way it does them.
# What is checked: nothing at all without the launcher or the configuration; the start (as nobody with the groups, a
# session of its own, an input that stays open and is not ours, nothing of root's in the private folder); a bridge that
# falls over started again, and the wait between starts, doubling to its cap and short again after a good run; a stop
# by its owner (the installer's, or bridge.sh stop) that holds, through a new supervisor in the same boot too, and the
# installer's start after it watched like one of ours; a supervisor that ends leaving its bridge to the next; what is
# refused (links, a bridge others can write, a folder that is not nobody's); and that main.sh and the bundles carry
# the script.
cd "$(dirname "$0")/../.."; Q=$(mktemp -d); fail=0
trap 'pkill -f "$Q/" 2>/dev/null; rm -rf "$Q"' EXIT
ok_() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; sed 's/^/     /' $Q/log $Q/runas.log 2>/dev/null; fail=1; fi; }

E=$Q/eb; P=$E/private; H=$Q/hm; ME=$(id -u); RSLEEP=$(command -v sleep); mkdir -p $Q/bin $Q/dev $H
sed "s#/data/local/echo-bridge#$E#g; s#/data/local/hassmic#$H#g; s#^SH=/system/bin/sh\$#SH=/bin/sh#; s#^OWNER=9999 #OWNER=$ME #; s#^ROOT=0\$#ROOT=$ME#" \
    scripts/device/bridge.sh > $Q/dev/bridge.sh
grep -q "^OWNER=$ME " $Q/dev/bridge.sh && grep -q "^ROOT=$ME\$" $Q/dev/bridge.sh && grep -q '^SH=/bin/sh$' $Q/dev/bridge.sh || { echo "FAIL the script's settings are not where this test changes them"; exit 1; }
# sleep: the script's own looks (1 s, 5 s) are short here; the waits between starts are written down and cut short
cat > $Q/bin/sleep << EOF
#!/bin/sh
case "\$1" in 1) exec $RSLEEP 0.05;; 5) exec $RSLEEP 0.1;; 10) echo 10 >> $Q/settles; exec $RSLEEP 0.05;; esac
[ -z "\$FAKE_SLEEP" ] || { echo "\$1" >> "\$FAKE_SLEEP"; exec $RSLEEP 0.02; }
exec $RSLEEP "\$@"
EOF
cat > $Q/bin/ps << EOF
#!/bin/sh
case "\$*" in *ARGS*) exec $(command -v ps) -e -o args;; esac
echo NAME; echo sh
pgrep -f "^/bin/sh $E/bin/echo-bridge --config" > /dev/null && echo echo-bridge
exit 0
EOF
# getprop: the Echo's resolvers while $Q/net is there (lockdown.sh's look), no other property
cat > $Q/bin/getprop << EOF
#!/bin/sh
[ \$# = 0 ] && [ -e $Q/net ] && echo "[net.dns1]: [192.0.2.1]"
exit 0
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
tr '\\0' ' ' < /proc/\$sid/cmdline | grep -q "$P/launch.sh" && [ "\$sid" != "\$(cat $Q/testsid)" ] && echo own >> $Q/session
[ -e /proc/\$\$/fd/3 ] && echo open >> $Q/fd3
readlink /proc/\$\$/fd/0 >> $Q/stdin
echo "\$*" >> $Q/args
echo \$\$ >> $Q/starts
echo "said by the bridge"
case "\$(cat $Q/mode)" in
eof)  cat > /dev/null; echo \$\$ >> $Q/eof; exit 0;;
fail) [ "\$(wc -l < $Q/starts)" -lt "\$(cat $Q/until)" ] || rm -f $P/bridge.toml; exit 7;;
deaf) cat > /dev/null; while :; do $RSLEEP 0.1; done;;
esac
EOF
# portos-echo scripts/echo-install.sh, write_launcher: the launcher's text as it is on the Echo
cat > $Q/launch.sh << 'LAUNCH'
#!/system/bin/sh
umask 077
state=/data/local/echo-bridge/private/run
# Atomic admission: cancellation may have consumed this gate first.
rmdir "$state/control" 2>/dev/null || exit 1
if test -f "$state/stop"; then touch "$state/finished"; exit 1; fi
# Only this session holds the write end. The bridge must not inherit it.
exec 3<> "$state/stdin"
/data/local/echo-bridge/bin/echo-bridge --config /data/local/echo-bridge/private/bridge.toml --trace /data/local/echo-bridge/private/bridge.trace < "$state/stdin" 3>&- &
child=$!
(while test ! -f "$state/stop"; do sleep 1; done; exec 3>&-) &
holder=$!
exec 3>&-
wait "$child"
# This child is still ours and unreaped, so its PID cannot have been reused.
kill "$holder" 2>/dev/null || :
wait "$holder" 2>/dev/null || :
touch "$state/finished"
LAUNCH
sed -i "s#/data/local/echo-bridge#$E#g; s#/system/bin/sh#/bin/sh#" $Q/launch.sh
chmod 755 $Q/bin/* $Q/dev/runas $Q/bridge
read -r _ _ _ _ _ testsid _ < /proc/$$/stat; echo $testsid > $Q/testsid
BOOT=$(cat /proc/sys/kernel/random/boot_id)

B() { PATH=$Q/bin:$PATH sh $Q/dev/bridge.sh "$@"; }
S() { FAKE_SLEEP=$Q/sleeps PATH=$Q/bin:$PATH exec sh ${1:-$Q/dev/bridge.sh} run < /dev/null >> $Q/log 2>&1; }      # with &: $! is the supervisor itself
fresh() {
    pkill -f "$Q/dev/bridge" 2>/dev/null; pkill -f "$P/launch.sh" 2>/dev/null; pkill -f "$E/bin/echo-bridge" 2>/dev/null
    rm -rf $E $E.lock $H/bridge.pid $H/bridge.parked $Q/log $Q/runas.log $Q/session $Q/fd3 $Q/stdin $Q/args $Q/starts $Q/eof $Q/sleeps $Q/settles
    touch $Q/net
}
# the installer's layout: bin/ closed to others, private/ and home/ the bridge user's own
opted() {
    fresh; mkdir -p $E/bin $P $E/home; chmod 755 $E $E/bin; chmod 700 $P $E/home
    cp $Q/bridge $E/bin/echo-bridge; chmod 755 $E/bin/echo-bridge
    cp $Q/launch.sh $P/launch.sh; chmod 700 $P/launch.sh; echo '[echo]' > $P/bridge.toml; chmod 600 $P/bridge.toml; echo $1 > $Q/mode
}
until_() { i=0; until eval "$1" 2>/dev/null; do i=$((i + 1)); [ $i -lt 100 ] || return 1; sleep 0.1; done; }
lines() { wc -l < $1 2>/dev/null || echo 0; }
last() { tail -n 1 $Q/starts; }
# the installer's stop (close_stdin, then private/run/ removed) and start (the gate, the FIFO, the launcher)
inst_stop() {
    if rmdir $P/run/control 2>/dev/null; then touch $P/run/finished; else touch $P/run/stop; fi
    until_ '[ -f $P/run/finished ]' || return 1
    sleep ${1:-0}; rm -rf $P/run
}
inst_start() {
    ( umask 077; mkdir $P/run $P/run/control && mkfifo $P/run/stdin ) || return 1
    PATH=$Q/bin:$PATH setsid /bin/sh $P/launch.sh < /dev/null >> $P/bridge.log 2>&1 &
}

# --- not opted in: nothing happens
fresh; B run > $Q/out 2>&1; r=$?
[ $r = 0 ] && [ ! -s $Q/out ] && [ ! -e $Q/runas.log ] && [ ! -e $E ] && [ "$(ls $H)" = "" ]; ok_ $? "no bridge folder: run ends at once, says nothing, starts nothing"
opted eof; rm $P/bridge.toml; B run > $Q/out 2>&1; r=$?
[ $r = 0 ] && [ ! -s $Q/out ] && [ ! -e $Q/runas.log ] && [ "$(ls $P)" = "launch.sh" ] && [ "$(ls $H)" = "" ]; ok_ $? "the launcher without a configuration: nothing, and nothing written"
opted eof; rm $P/launch.sh; B run > $Q/out 2>&1; r=$?
[ $r = 0 ] && [ ! -s $Q/out ] && [ ! -e $Q/runas.log ] && [ "$(ls $P)" = "bridge.toml" ]; ok_ $? "a configuration without the launcher (not installed by the installer): nothing"
opted eof; mv $P/launch.sh $Q/elsewhere.sh; ln -s $Q/elsewhere.sh $P/launch.sh; B run > $Q/out 2>&1; r=$?
[ $r = 0 ] && [ ! -e $Q/runas.log ]; ok_ $? "the launcher a link: not run"
fresh; B start > $Q/out 2>&1; [ $? = 0 ] && grep -q 'nothing to start' $Q/out && [ ! -e $H/boot.log ]; ok_ $? "start by hand without them: says so, starts nothing"
fresh; B stop > $Q/out 2>&1; [ $? = 0 ] && grep -q 'not running' $Q/out; ok_ $? "stop with nothing running"

# --- the start
opted eof; S & sup=$!
until_ '[ -s $Q/starts ]'; ok_ $? "with both there the bridge starts"
[ "$(grep -c '^nobody 3990,inet /bin/sh -c umask 077; ' $Q/runas.log)" = 2 ] && [ "$(grep -c '/bin/sh -c' $Q/runas.log)" = 2 ] && grep -q "exec /bin/sh $P/launch.sh < /dev/null >> $P/bridge.log 2>&1" $Q/runas.log
ok_ $? "through the installer's launcher, as nobody with group 3990 and inet: nothing as root"
[ "$(cat $Q/args)" = "--config $P/bridge.toml --trace $P/bridge.trace" ]; ok_ $? "the configuration and the trace in its private folder"
[ "$(cat $Q/session)" = own ]; ok_ $? "in a session of its own, the launcher's"
[ "$(cat $Q/stdin)" = "$P/run/stdin" ] && [ -p $P/run/stdin ] && [ ! -e $Q/fd3 ]; ok_ $? "its input the installer's FIFO, the writing end not handed to it"
until_ '[ ! -e $E.lock ]' && [ ! -d $P/run/control ] && [ "$(stat -c %a $P/run)" = 700 ]; ok_ $? "the gate taken by the launcher, the installer's lock given back"
[ "$(stat -c %a $P/bridge.log)" = 600 ] && grep -q 'said by the bridge' $P/bridge.log && ! grep -q 'said by the bridge' $Q/log
ok_ $? "what the bridge says: a private file, not the boot log"
until_ 'grep -q "bridge: started as nobody" $Q/log' && [ "$(cat $H/bridge.pid)" = $sup ]; ok_ $? "the start in the log, the supervisor's pid in hassmic's folder"
sleep 1.5; [ "$(lines $Q/starts)" = 1 ] && [ ! -e $Q/eof ] && kill -0 $(last); ok_ $? "its input stays open: still the first one after 1.5 s"

[ "$(cat $Q/settles)" = 10 ]; ok_ $? "its first start 10 s after a resolver was seen (lockdown.sh lets it through meanwhile)"

# --- it falls over: started again
kill -KILL $(last); until_ '[ "$(lines $Q/starts)" = 2 ]' && grep -q 'bridge: exited after [0-9]* s, restart in 3 s' $Q/log && [ "$(cat $Q/sleeps)" = 3 ]
ok_ $? "the bridge killed: said in the log, started again after the wait"
pkill -KILL -f "$P/launch.sh"; kill -KILL $(last); until_ '[ "$(lines $Q/starts)" = 3 ]' && grep -q 'bridge: gone after' $Q/log
ok_ $? "the launcher gone with it (nothing left to say it finished, as under the Echo's shell): started again too"
grep -qx "nobody 3990,inet /bin/sh -c touch $P/run/finished" $Q/runas.log; ok_ $? "and \`finished\` left in the launcher's place, as nobody, for the installer's stop to find"
# the same while its owner stops it: the installer's stop gets the \`finished\` it waits for
touch $P/run/stop; pkill -KILL -f "$P/launch.sh"; kill -KILL $(last); until_ '[ -f $P/run/finished ]'; r=$?; rm -rf $P/run; sleep 0.5
[ $r = 0 ] && [ "$(lines $Q/starts)" = 3 ] && grep -q 'stopped by its owner' $Q/log; ok_ $? "the same during a stop by its owner: \`finished\` left, nothing started"
inst_start; until_ '[ "$(lines $Q/starts)" = 4 ]' && until_ 'grep -q "started by its owner: watched from here" $Q/log'; ok_ $? "(started again by the installer for what follows)"

# --- no network yet (the boot, before DHCP is done): the start waits for a resolver
opted eof; rm $Q/net; S & sup=$!
until_ 'grep -q "no network yet" $Q/log' && sleep 0.5 && [ ! -e $Q/starts ] && [ ! -e $Q/runas.log ] && [ ! -e $P/run ] && [ "$(grep -c 'no network yet' $Q/log)" = 1 ]
ok_ $? "no resolver known: said once, nothing started, nothing made"
touch $Q/net; until_ '[ -s $Q/starts ]' && [ "$(cat $Q/settles)" = 10 ] && [ "$(lines $Q/starts)" = 1 ]; ok_ $? "a resolver turns up: started 10 s later, once"
rm $Q/net; kill -KILL $(last); until_ 'grep -q "restart in 3 s" $Q/log' && until_ '[ "$(grep -c "no network yet" $Q/log)" = 2 ]' && sleep 0.5 && [ "$(lines $Q/starts)" = 1 ]
ok_ $? "it falls over with the network gone: not started again without one"
touch $Q/net; until_ '[ "$(lines $Q/starts)" = 2 ]' && [ "$(lines $Q/settles)" = 2 ]; ok_ $? "the network back: started again, 10 s after its resolver"
opted eof; rm $Q/net; S & sup=$!
until_ 'grep -q "no network yet" $Q/log'; kill $sup; until_ '! kill -0 $sup' && grep -q 'supervisor ended' $Q/log && [ ! -e $H/bridge.pid ] && [ ! -e $Q/starts ]
ok_ $? "the supervisor ended during that wait: gone at once, nothing started"
opted eof; rm $Q/net; S & sup=$!
until_ 'grep -q "no network yet" $Q/log'; inst_start; until_ '[ -s $Q/starts ]'; touch $Q/net; until_ '[ -s $Q/settles ]'; sleep 0.5
[ "$(lines $Q/starts)" = 1 ] && kill -0 $(last) && ! grep -q 'bridge: started as nobody' $Q/log; ok_ $? "the installer's start during that wait: its bridge left running, none started beside it"
kill -KILL $(last); until_ '[ "$(lines $Q/starts)" = 2 ]'; ok_ $? "and watched: started again when it falls over"

# --- stopped by its owner: the installer's stop holds, the installer's start is watched like one of ours
n=$(lines $Q/starts); b=$(last); inst_stop 0.5; r=$?
[ $r = 0 ] && grep -qx $b $Q/eof && ! kill -0 $b 2>/dev/null; ok_ $? "the installer's stop: the bridge saw the end of its input and ended itself"
sleep 1; [ "$(lines $Q/starts)" = $n ] && kill -0 $sup && grep -q 'stopped by its owner' $Q/log && [ "$(cat $H/bridge.parked)" = "$BOOT" ]
ok_ $? "and it is not started again: the supervisor waits"
inst_start; until_ '[ "$(lines $Q/starts)" = $((n + 1)) ]' && until_ 'grep -q "started by its owner: watched from here" $Q/log' && [ ! -e $H/bridge.parked ]
ok_ $? "the installer's start after it: seen"
kill -KILL $(last); until_ '[ "$(lines $Q/starts)" = $((n + 2)) ]'; ok_ $? "and that bridge killed: started again"
n=$(lines $Q/starts); inst_stop
sleep 1; [ "$(lines $Q/starts)" = $n ] && kill -0 $sup; ok_ $? "private/run/ taken away as soon as it finished: stopped by its owner all the same"

# --- bridge.sh stop and start
B start > $Q/out 2>&1; r=$?
[ $r = 0 ] && until_ '[ "$(lines $Q/starts)" = $((n + 1)) ]' && ! kill -0 $sup 2>/dev/null && [ ! -e $H/bridge.parked ]; ok_ $? "start by hand: a new supervisor takes over and starts it"
sup2=$(cat $H/bridge.pid); b=$(last)
B stop > $Q/out 2>&1; r=$?
[ $r = 0 ] && grep -q 'bridge: stopped' $Q/out && grep -qx $b $Q/eof && [ ! -e $P/run ] && [ ! -e $E.lock ] && [ "$(cat $H/bridge.parked)" = "$BOOT" ]; ok_ $? "stop: the installer's stop, done as nobody"
sleep 1; [ "$(lines $Q/starts)" = $((n + 1)) ] && kill -0 $sup2; ok_ $? "and it is not started again"
kill $sup2; until_ '! kill -0 $sup2'
S & sup=$!
until_ 'grep -q "stopped by its owner in this boot: not started" $Q/log'; r=$?; sleep 0.5
[ $r = 0 ] && [ "$(lines $Q/starts)" = $((n + 1)) ]; ok_ $? "a new supervisor in the same boot (the satellite service started again): still stopped"
kill $sup; until_ '! kill -0 $sup'
echo another-boot > $H/bridge.parked; mkdir $P/run; touch $P/run/stop $P/run/finished
S & sup=$!
until_ '[ "$(lines $Q/starts)" = $((n + 2)) ]'; ok_ $? "after a reboot: started, whatever private/run/ still held"
opted deaf; S & sup=$!
until_ '[ -s $Q/starts ]'; sed -i 's/^STOP_WAIT=20$/STOP_WAIT=3/' $Q/dev/bridge.sh; B stop > $Q/out 2>&1; r=$?
[ $r = 1 ] && grep -q 'no process was signalled' $Q/out && kill -0 $(last) && [ -d $P/run ] && [ ! -e $E.lock ]; ok_ $? "a bridge that ignores the end of its input: stop says so and signals nothing"
sed -i 's/^STOP_WAIT=3$/STOP_WAIT=20/' $Q/dev/bridge.sh

# --- a supervisor that ends (the service stopped, an update): its bridge stays for the next one
opted eof; S & sup=$!
until_ '[ -s $Q/starts ]'; { kill -KILL $sup; wait $sup; } 2> /dev/null; sleep 0.5
kill -0 $(last) && [ ! -e $Q/eof ]; ok_ $? "the supervisor killed: the bridge runs on"
S & sup=$!
until_ 'grep -q "a bridge runs already: watched from here" $Q/log'; r=$?; sleep 0.5
[ $r = 0 ] && [ "$(lines $Q/starts)" = 1 ]; ok_ $? "the next supervisor: watches that bridge, starts none"
kill -KILL $(last); until_ '[ "$(lines $Q/starts)" = 2 ]'; ok_ $? "and starts it again when it falls over"
S & sup2=$!
until_ '! kill -0 $sup 2>/dev/null' && until_ '[ "$(cat $H/bridge.pid)" = $sup2 ]'; r=$?; sleep 0.5
[ $r = 0 ] && kill -0 $sup2 && [ "$(lines $Q/starts)" = 2 ] && [ "$(pgrep -f "^/bin/sh $E/bin/echo-bridge --config" | wc -l)" = 1 ]; ok_ $? "a second supervisor: the first ends, one bridge all along"
# an echo-bridge of someone else's (started by hand, another layout): left alone, none started beside it
opted eof; $RSLEEP 30 | /bin/sh $E/bin/echo-bridge --config hand > /dev/null 2>&1 &
until_ '[ -s $Q/starts ]'; S & sup=$!
until_ 'grep -q "did not start: left alone, none started" $Q/log'; r=$?; sleep 0.5
[ $r = 0 ] && [ "$(lines $Q/starts)" = 1 ] && [ ! -e $Q/runas.log ]; ok_ $? "an echo-bridge the launcher did not start: left alone, none started beside it"

# --- the wait between restarts
# (the start that takes the configuration away ends the supervisor before or after one more wait: the first ten count)
opted fail; echo 11 > $Q/until
FAKE_SLEEP=$Q/sleeps B run < /dev/null >> $Q/log 2>&1; r=$?
[ "$(head -n 10 $Q/sleeps | tr '\n' ' ')" = "3 6 12 24 48 96 192 300 300 300 " ]; ok_ $? "a bridge that exits at once: 3 s, doubled each time, 5 min at most ($(tr '\n' ' ' < $Q/sleeps))"
[ $r = 0 ] && [ "$(lines $Q/starts)" = 11 ] && grep -q 'exited after [01] s, restart in 3 s' $Q/log && grep -q 'is gone: supervisor ended' $Q/log && [ ! -e $H/bridge.pid ]
ok_ $? "each exit in the log; the configuration taken away: the supervisor ends"
opted fail; echo 5 > $Q/until; sed -i 's/^GOOD_RUN=60$/GOOD_RUN=0/' $Q/dev/bridge.sh
FAKE_SLEEP=$Q/sleeps B run < /dev/null >> $Q/log 2>&1
[ "$(head -n 4 $Q/sleeps | tr '\n' ' ')" = "3 3 3 3 " ]; ok_ $? "after a run that was long enough: 3 s again"
sed -i 's/^GOOD_RUN=0$/GOOD_RUN=60/' $Q/dev/bridge.sh
opted fail; echo 99 > $Q/until
PATH=$Q/bin:$PATH sh $Q/dev/bridge.sh run < /dev/null >> $Q/log 2>&1 & sup=$!       # the wait as long as it is
until_ 'grep -q "restart in 3 s" $Q/log'; B stop > $Q/out 2>&1; r=$?; sleep 4
[ $r = 0 ] && kill -0 $sup && [ "$(lines $Q/starts)" = 1 ] && grep -q 'stopped by its owner' $Q/log; ok_ $? "stop during the wait: no second start"

# --- refused, as the installer refuses it: said once, nothing started, nothing touched
refused() {     # what was done to the layout, what the log must say
    S ${3:-} & sup=$!
    pat="not started: .*$2"; until_ 'grep -q "$pat" $Q/log'; r=$?; sleep 0.5
    [ $r = 0 ] && [ ! -e $Q/starts ] && [ ! -e $Q/runas.log ] && [ ! -e $P/run/control ] && [ "$(grep -c 'not started' $Q/log)" = 1 ] && kill -0 $sup; ok_ $? "$1: not started, said once"
}
opted eof; chmod 775 $E/bin/echo-bridge; refused "a bridge others can write" "is not root's alone"
opted eof; chmod 777 $E/bin; refused "bin/ open to others" "is not root's alone"
opted eof; mkdir $Q/away; ln -s $Q/away $P/run; refused "private/run a link" "is a link or not a folder"
[ "$(ls -A $Q/away)" = "" ]; ok_ $? "and nothing written behind that link"
opted eof; touch $Q/away/log; ln -s $Q/away/log $P/bridge.log; refused "bridge.log a link" "is a link"
opted eof; rm $E/bin/echo-bridge; refused "no bridge in bin/" "no $E/bin/echo-bridge"
opted eof; sed 's/^OWNER=[0-9]* /OWNER=12345 /' $Q/dev/bridge.sh > $Q/dev/bridge-owner.sh; refused "a private folder that is not nobody's" "is not nobody's" $Q/dev/bridge-owner.sh
opted eof; sed 's/^ROOT=[0-9]*$/ROOT=12345/' $Q/dev/bridge.sh > $Q/dev/bridge-root.sh; refused "a bin/ that is not root's" "is not root's alone" $Q/dev/bridge-root.sh
# put right and started by the installer: watched from then on
opted eof; chmod 775 $E/bin/echo-bridge; S & sup=$!
until_ 'grep -q "not started" $Q/log'; chmod 755 $E/bin/echo-bridge; inst_start
until_ 'grep -q "started by its owner: watched from here" $Q/log'; kill -KILL $(last); until_ '[ "$(lines $Q/starts)" = 2 ]'; ok_ $? "put right and started by the installer: watched, started again when it falls over"

# --- the installer's lock, and a launcher that cannot run
opted eof; mkdir $E.lock; sed 's/^LOCK_WAIT=60$/LOCK_WAIT=30/' $Q/dev/bridge.sh > $Q/dev/bridge-lock.sh; S $Q/dev/bridge-lock.sh & sup=$!
sleep 0.5; [ ! -e $Q/starts ]; r=$?
until_ '[ -s $Q/starts ]' && [ $r = 0 ] && grep -q 'starting without it' $Q/log && [ -d $E.lock ]; ok_ $? "the installer's lock held: waited for, then started without it, the lock left alone"
if [ $ME != 0 ]; then
    opted eof; touch $P/bridge.log; chmod 400 $P/bridge.log; S & sup=$!
    until_ 'grep -q "did not start within 20 s" $Q/log' && until_ 'grep -q "restart in 6 s" $Q/log' && [ ! -e $Q/starts ] && grep -q "rmdir $P/run/control && touch $P/run/finished" $Q/runas.log
    ok_ $? "a launcher that cannot run: its gate taken back, tried again after the wait"
else
    echo "skip a launcher that cannot run (root writes anywhere)"
fi
fresh

# --- carried by the boot script, the update bundle and the installers; parses as every script that goes on the Echo
grep -q '\[ -f \$D/bridge.sh \] && sh \$D/bridge.sh run < /dev/null >> \$LOG 2>&1 &' scripts/system/main.sh; ok_ $? "main.sh satellite starts it where the script is there"
for f in scripts/bundle.sh scripts/install-system.sh scripts/install-boot.sh; do grep -q 'scripts/device/bridge.sh' $f || { echo "$f" > $Q/log; false; break; }; done
ok_ $? "in the update bundle and both installers"
sh -n scripts/device/bridge.sh && sh -n scripts/system/main.sh; ok_ $? "both parse"
! grep -nE 'runas +root|\$RUNAS +root' scripts/device/bridge.sh; ok_ $? "nothing in it starts anything as root"
exit $fail
