#!/system/bin/sh
# Keeps portos-echo's bridge running beside hassmic: echo-bridge, a realtime voice client of hassmic's Wyoming port on
# the Echo itself (hassmic.conf: PROTO=wyoming, ARGS="-D").  Root's, next to main.sh, which starts it with the satellite.
#   bridge.sh run      the supervisor: starts the bridge and starts it again when it exits (main.sh satellite, start)
#   bridge.sh stop     the clean stop: the supervisor closes the bridge's input, waits for it and ends
#   bridge.sh start    the supervisor in a session of its own, for a start by hand after a stop
# Nothing happens unless both are on the Echo, put there by its owner:
#   /data/local/echo-bridge/echo-bridge             the bridge (an armv7 Android binary)
#   /data/local/echo-bridge/private/bridge.toml     its configuration
# Without either, run ends at once and says nothing: hassmic as ever.  Take the configuration away and the bridge is not
# started again.  The folder private/ is the bridge's own (root's, mode 700): its trace, what it says (bridge.log) and
# what its configuration keeps there (credentials, the Codex home, the audit log).  This script reads none of it.
#
# What the bridge needs to run on an Echo (portos-echo docs/architecture.md, "Launch contract on the Echo", measured
# on a device on 2026-11-18):
# - Group 3990 beside inet.  lockdown.sh lets only that group out (NET_GID), so a bridge started as plain root reached
#   hassmic over lo and then waited for the network until its deadline.  No rule changes for it: runas gives the group.
# - A session of its own (setsid).  Left in the process group of the adb shell that started it, it got SIGTERM some 17 s
#   after the start.
# - An input that stays open.  The end of its input is the bridge's request to stop, so with < /dev/null it stops at
#   once.  It reads a FIFO whose writing end this supervisor holds and never writes to: closing it is the clean stop,
#   and a supervisor that dies (the satellite service stopped, an update) closes it too.  Every other exit is a failure,
#   and the bridge never starts itself again: that is the loop below.
# - umask 077: the bridge makes its own files private whatever the umask, but not the file its output goes to.
# The wait before the next start doubles from 3 s to 5 min while the bridge keeps exiting within a minute, and is 3 s
# again after a run of a minute or more: a bridge that cannot start (no network, a broken configuration, a login that
# ran out) does not spin, and one that fell over after hours is back at once.
umask 077
BR=/data/local/echo-bridge
BIN=$BR/echo-bridge
PRIV=$BR/private
CONF=$PRIV/bridge.toml
TRACE=$PRIV/trace.jsonl
OUT=$PRIV/bridge.log
FIFO=$PRIV/stdin
SUP=$PRIV/supervisor.pid
PID=$PRIV/bridge.pid
LOG=/data/local/hassmic/boot.log
HERE=$(cd "$(dirname "$0")" && pwd)
RUNAS=$HERE/runas
SELF=${0##*/}
BACKOFF_MIN=3
BACKOFF_MAX=300
GOOD_RUN=60
STOP_WAIT=10
OUT_MAX=1048576

# as main.sh stamps the log's lines: UTC once the clock was set from Home Assistant, else seconds since boot
stamp() { if [ "$(getprop hassmic.clock.synced 2>/dev/null)" = 1 ]; then date -u '+%Y-%m-%d %H:%M:%SZ'; else read -r u _ < /proc/uptime; echo "boot+$u"; fi; }
say() { echo "$(stamp) bridge: $*"; }
up() { cut -d. -f1 /proc/uptime; }
# Both there, as plain files in plain folders: root runs the one and hands the other to it, never through a link.
wanted() { [ -f $BIN ] && [ -f $CONF ] && [ ! -L $BIN ] && [ ! -L $CONF ] && [ ! -L $BR ] && [ ! -L $PRIV ]; }
# the process a pid file names, if it still is what the file was written for (TEXT in its command line)
pid_in() { p=$(cat "$1" 2>/dev/null); case "$p" in ''|*[!0-9]*) return 1;; esac; grep -qF -- "$2" /proc/$p/cmdline 2>/dev/null && echo $p; }
# gone PID SECONDS: true once that process is gone (not for a child of ours: one that ended stays until waited for)
gone() {
    i=0
    while kill -0 $1 2>/dev/null; do
        [ $i -lt $2 ] || return 1
        sleep 1; i=$((i + 1))
    done
}
# A supervisor that runs already ends first, with its bridge: the one started last is the one that runs (the satellite
# service started again takes over from a start by hand, an update's script from the one before it).
halt() {
    s=$(pid_in $SUP $SELF) || return 0
    [ "$s" != $$ ] || return 0
    kill -TERM $s 2>/dev/null
    gone $s $((STOP_WAIT + 10)) && return 0
    say "supervisor $s did not stop within $((STOP_WAIT + 10)) s, killed"; kill -KILL $s 2>/dev/null; gone $s 5
}

case "$1" in
run)
    wanted || exit 0
    [ -x $RUNAS ] || { say "no $RUNAS: not started"; exit 1; }
    halt
    # Root runs what is here: nobody else may write it (the bridge's neighbours too: its configuration names an app
    # server there, which it runs), and nobody else reads the bridge's own folder.  What adb left (it creates with
    # umask 000) is put right, as boot.sh does for hassmic's folder.
    chown root:root $BR $BIN $PRIV $CONF && chmod 755 $BR $BIN && chmod go-w $BR/* && chmod 700 $PRIV && chmod 600 $CONF && cd $PRIV ||
        { say "cannot make $BR root's own: not started"; exit 1; }
    echo $$ > $SUP
    # A bridge whose supervisor was killed has had its input closed and is on its way out; the new one waits for it
    # (the two would fight over the ports and the Codex home).
    if b=$(pid_in $PID $BIN); then
        gone $b $STOP_WAIT || { say "the bridge before this one (pid $b) is still there after $STOP_WAIT s, ended"; kill -TERM $b 2>/dev/null; gone $b 5 || kill -KILL $b 2>/dev/null; }
    fi
    [ -p $FIFO ] || { rm -f $FIFO; mkfifo $FIFO 2>/dev/null || mknod $FIFO p; } || { say "cannot make $FIFO: not started"; exit 1; }
    exec 3<> $FIFO || { say "cannot open $FIFO: not started"; exit 1; }     # read-write: the open does not wait for a reader
    # The stop, all of it in the signal's handler, which never goes back to the loop: a flag for the loop to look at
    # would be missed by a signal that comes just before the loop waits.  $! is what the loop started last: the bridge
    # (its input closed here; one that does not take the hint gets SIGTERM, then SIGKILL) or the sleep between two.
    # wait says 127 for what is not ours to wait for: never a loop on it.
    phase=
    stop() {
        trap '' TERM INT HUP
        c=$!
        exec 3>&-
        if [ "$phase" = bridge ]; then
            ( sleep $STOP_WAIT; kill -TERM $c; sleep 5; kill -KILL $c ) > /dev/null 2>&1 &
            k=$!
            rc=none
            while kill -0 $c 2>/dev/null; do wait $c; rc=$?; [ $rc != 127 ] || break; done
            kill $k 2>/dev/null
            say "stopped (its input closed, rc=$rc)"
        else
            [ -z "$c" ] || kill $c 2>/dev/null
            say "stopped"
        fi
        rm -f $PID $SUP
        exit 0
    }
    trap stop TERM INT HUP
    delay=$BACKOFF_MIN
    while wanted; do
        # what the bridge says: one old part kept, moved away while no bridge writes to it
        [ -f $OUT ] && [ "$(wc -c < $OUT)" -gt $OUT_MAX ] && mv $OUT $OUT.1
        t0=$(up)
        # setsid from a background job execs, and so does runas: $! is the bridge.  Its input the FIFO's reading end,
        # and not our writing end with it (3>&-), or closing ours would not be the end of its input.
        phase=bridge
        setsid $RUNAS root 3990,inet $BIN --config $CONF --trace $TRACE < $FIFO >> $OUT 2>&1 3>&- &
        b=$!
        echo $b > $PID
        say "started (pid $b), what it says is in $OUT"
        wait $b; rc=$?
        rm -f $PID
        ran=$(( $(up) - t0 ))
        [ $ran -lt $GOOD_RUN ] || delay=$BACKOFF_MIN
        say "exited rc=$rc after $ran s, restart in $delay s"
        phase=pause
        sleep $delay 3>&- &
        wait $!
        if [ $ran -lt $GOOD_RUN ]; then
            delay=$((delay * 2)); [ $delay -le $BACKOFF_MAX ] || delay=$BACKOFF_MAX
        fi
    done
    rm -f $SUP
    say "$BIN or $CONF is gone: not started again"
    ;;
stop)
    s=$(pid_in $SUP $SELF) || { echo "bridge: not running"; exit 0; }
    kill -TERM $s
    gone $s $((STOP_WAIT + 10)) || { echo "bridge: supervisor $s did not stop"; exit 1; }
    echo "bridge: stopped"
    ;;
start)
    wanted || { echo "bridge: no $BIN or no $CONF, nothing to start"; exit 0; }
    setsid sh "$0" run < /dev/null >> $LOG 2>&1 &
    echo "bridge: starting, see $LOG"
    ;;
*)
    echo "usage: bridge.sh run|stop|start"; exit 2
    ;;
esac
