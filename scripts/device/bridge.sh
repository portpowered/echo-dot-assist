#!/system/bin/sh
# Keeps portos-echo's bridge running beside hassmic: echo-bridge, a realtime voice client of hassmic's Wyoming port on
# the Echo itself (hassmic.conf: PROTO=wyoming, ARGS="-D").  Root's, next to main.sh, which starts it with the satellite.
#   bridge.sh run      the supervisor: starts the bridge, watches it and starts it again after an exit nobody asked for
#   bridge.sh stop     the clean stop, as portos-echo's `echo-install.sh stop` does it; the bridge then stays stopped
#   bridge.sh start    a supervisor in a session of its own, for a start by hand after a stop
# Nothing happens unless portos-echo's installer (scripts/echo-install.sh there) left both on the Echo:
#   /data/local/echo-bridge/private/launch.sh       its launcher (written by the installer's install and start)
#   /data/local/echo-bridge/private/bridge.toml     the bridge's configuration
# Without either, run ends at once and says nothing: hassmic as ever.  Take one away (the installer's uninstall does)
# and the supervisor ends.
#
# The installer's layout, which this script only ever uses and never makes or repairs:
#   bin/        root's, mode 755: echo-bridge, the app server it starts, their certificates
#   private/    nobody's (uid 9999), mode 700: the configuration, launch.sh, bridge.log, the trace, credentials
#   home/       nobody's, mode 700: what the bridge's agent keeps
# and the installer's start, which is the one way a bridge is started here too (portos-echo docs/architecture.md,
# "Launch contract on the Echo"):
#   setsid runas nobody 3990,inet /system/bin/sh private/launch.sh < /dev/null >> private/bridge.log 2>&1
# - As Android's user nobody, never root, with group 3990 beside inet: lockdown.sh lets only that group out (NET_GID).
#   No rule changes for it: runas gives the group.
# - A session of its own (setsid), so it is in nobody's process group but its own.
# - An input that stays open: the end of its input is the bridge's request to stop.  launch.sh gives it the reading
#   end of the FIFO private/run/stdin and holds the writing end itself, until private/run/stop is there.
# private/run/ is the installer's own protocol, kept to the letter so that the installer and this script can be used on
# the same bridge in any order:
#   control/    the gate of one start: launch.sh takes it away (rmdir) before it starts the bridge; whoever takes it
#               first instead has cancelled that start
#   stdin       the FIFO
#   stop        asked to stop: launch.sh closes the bridge's input
#   finished    launch.sh is done, the bridge it started has ended
# The installer's stop sets `stop`, waits for `finished` and removes private/run/.  So for the supervisor:
#   `finished` without `stop`, or no bridge where one should be    it fell over: started again after a wait
#   `stop`, or private/run/ taken away                             its owner stopped it: not started again
# The second case of the first line is the usual one on an Echo: under its shell (mksh) the launcher ends without
# leaving `finished` when the bridge ends by itself (measured on a Show 8, 2026-11-19: the launcher is gone right after
# it ended the holder of the input).  The supervisor then leaves `finished` in its place, as nobody, once neither the
# bridge nor the launcher is there: the installer's stop and start wait for that file.
# until the installer's start (seen by its bridge running: watched from then on like one of ours), `bridge.sh start` or
# a reboot.  A stop holds through a restart of the satellite service in the same boot (bridge.parked names the boot).
#
# Root writes nothing into private/ here.  It is nobody's folder, and what root wrote or removed there by a name could
# be pointed elsewhere: private/run/ is made, and the bridge's output file opened, as nobody (runas), and root only
# looks.  Root never runs what nobody can write either: launch.sh runs as nobody, and before every start the layout is
# checked as the installer checks it (no links, bin/ root's and closed to others, private/ nobody's); what does not
# fit is said in the log and not started.
# The wait before the next start doubles from 3 s to 5 min while the bridge keeps exiting within a minute, and is 3 s
# again after a run of a minute or more: a bridge that cannot start (no network, a broken configuration, a login that
# ran out) does not spin, and one that fell over after hours is back at once.
#
# The clock.  Nothing else sets it on an Echo that is not Home Assistant's: lockdown.sh lets only NET_GID out, so
# Android's own network time gets no answer, and the Echo runs on whatever its clock held (17.5 h behind, measured
# 2026-11-19).  The bridge measures the time for itself, but certificates are checked against the system clock.  So
# before a start, and every 6 h while the supervisor runs and the bridge is not parked, root asks the bridge's own
# binary to set it: `echo-bridge clock sync` (SNTP to a few public servers, a majority of at least two in agreement,
# the clock set when it is a second or more off), with group 3990 so the firewall lets it out, without the bridge's
# configuration (nobody's, not for root to act on) and only where the layout is as the installer left it (bin/ root's
# alone).  It is the one thing here that runs as root.  What it said is one line in the log; no answer within
# CLOCK_WAIT seconds and it is ended and the start goes on: a start never waits longer for the clock.  A clock that
# was set is written to the RTC, as main.sh does after Home Assistant's time.  A bridge that restarts within a minute
# does not ask again.
umask 077
BR=/data/local/echo-bridge
BIN=$BR/bin/echo-bridge
PRIV=$BR/private
RUN=$PRIV/run
LAUNCH=$PRIV/launch.sh
CONF=$PRIV/bridge.toml
OUT=$PRIV/bridge.log
LOCK=/data/local/echo-bridge.lock           # the installer's: one of us at a time prepares a start
BASE=/data/local/hassmic
LOG=$BASE/boot.log
SUP=$BASE/bridge.pid                        # root's own folder: the supervisor's pid
PARK=$BASE/bridge.parked                    # the boot in which its owner stopped the bridge
SH=/system/bin/sh
HERE=$(cd "$(dirname "$0")" && pwd)
RUNAS=$HERE/runas
SELF=${0##*/}
AS_USER=nobody
AS_GROUPS=3990,inet
OWNER=9999                                  # nobody
ROOT=0
POLL=5
BACKOFF_MIN=3
BACKOFF_MAX=300
GOOD_RUN=60
START_WAIT=20
STOP_WAIT=20
LOCK_WAIT=60
NET_SETTLE=10
OUT_MAX=1048576
CLOCK_EVERY=21600
CLOCK_WAIT=6
CLOCK_OUT=$BASE/bridge.clock                # root's own folder: what clock sync said

# as main.sh stamps the log's lines: UTC once the clock was set from Home Assistant, else seconds since boot
stamp() { if [ "$(getprop hassmic.clock.synced 2>/dev/null)" = 1 ]; then date -u '+%Y-%m-%d %H:%M:%SZ'; else read -r u _ < /proc/uptime; echo "boot+$u"; fi; }
say() { echo "$(stamp) bridge: $*"; }
up() { cut -d. -f1 /proc/uptime; }
# Opted in: the installer's launcher and a configuration, as plain files in plain folders
wanted() { [ -f $LAUNCH ] && [ -f $CONF ] && [ ! -L $LAUNCH ] && [ ! -L $CONF ] && [ ! -L $BR ] && [ ! -L $PRIV ]; }
# by its exact name, as the installer looks (a pattern over command lines would find this script's own neighbours)
running() { ps -A -o NAME 2>/dev/null | grep -qx echo-bridge; }
# the installer's launcher (or the part of it that holds the bridge's input): a whole command line, so not this grep
launcher() { ps -A -o ARGS 2>/dev/null | grep -qE "^($SH|sh) $LAUNCH\$"; }
as_bridge() { $RUNAS $AS_USER $AS_GROUPS $SH -c "$1" < /dev/null; }
owner() { stat -c %u "$1" 2>/dev/null; }
# closed to everyone but its owner for writing
closed() { case "$(stat -c %A "$1" 2>/dev/null)" in ''|?????w*|????????w*) return 1;; esac; }
# What the installer refuses, refused here: says why (one line) and fails
unsafe() {
    for p in $BR $BR/bin $PRIV $BR/home $RUN; do
        [ ! -L $p ] && { [ ! -e $p ] || [ -d $p ]; } || { echo "$p is a link or not a folder"; return 0; }
    done
    for p in $LAUNCH $OUT $CONF $PRIV/bridge.trace $RUN/stdin $RUN/control $RUN/stop $RUN/finished $BIN; do
        [ ! -L $p ] || { echo "$p is a link"; return 0; }
    done
    [ -f $BIN ] && [ -x $BIN ] || { echo "no $BIN"; return 0; }
    for p in $BR $BR/bin $BIN; do
        [ "$(owner $p)" = $ROOT ] && closed $p || { echo "$p is not root's alone"; return 0; }
    done
    for p in $PRIV $LAUNCH $CONF; do
        [ "$(owner $p)" = $OWNER ] || { echo "$p is not $AS_USER's"; return 0; }
    done
    [ ! -e $OUT ] || { [ -f $OUT ] && [ "$(owner $OUT)" = $OWNER ]; } || { echo "$OUT is not $AS_USER's"; return 0; }
    return 1
}
# the process a pid file names, if it still is what the file was written for (TEXT in its command line)
pid_in() { p=$(cat "$1" 2>/dev/null); case "$p" in ''|*[!0-9]*) return 1;; esac; grep -qF -- "$2" /proc/$p/cmdline 2>/dev/null && echo $p; }
# gone PID SECONDS: true once that process is gone
gone() {
    i=0
    while kill -0 $1 2>/dev/null; do
        [ $i -lt $2 ] || return 1
        sleep 1; i=$((i + 1))
    done
}
# A supervisor that runs already ends first; its bridge stays and is watched by the one started last (the satellite
# service started again takes over from a start by hand, an update's script from the one before it).
halt() {
    s=$(pid_in $SUP $SELF) || return 0
    [ "$s" != $$ ] || return 0
    kill -TERM $s 2>/dev/null
    gone $s 15 && return 0
    say "supervisor $s did not end within 15 s, killed"; kill -KILL $s 2>/dev/null; gone $s 5
}
boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }

case "$1" in
run)
    wanted || exit 0
    [ -x $RUNAS ] || { say "no $RUNAS: not started"; exit 1; }
    cd /
    halt
    echo $$ > $SUP
    nap=
    bye() {
        trap '' TERM INT HUP
        [ -z "$nap" ] || kill $nap 2>/dev/null
        [ "$(cat $SUP 2>/dev/null)" != $$ ] || rm -f $SUP
        say "supervisor ended (a bridge that runs stays, for the next one)"
        exit 0
    }
    trap bye TERM INT HUP
    boot=$(boot_id)
    parked="" delay=$BACKOFF_MIN t0=$(up) missing=0 clock_at=""
    # A start waits for the network.  A bridge started before the Echo has one cannot log in, says that its login has
    # to be made again and stays so until it is started again: seen at boot, the start 21 s after it and a second
    # before DHCP was done.  The network is there once a resolver is known, as lockdown.sh finds them; lockdown.sh
    # lets a new resolver through on its next look (5 s), hence the wait after one turned up.  This supervisor's
    # first start waits that long with a resolver known too: at boot it may be a second old.
    online() { getprop 2>/dev/null | grep -qE '^\[(dhcp\.[^.]+|net)\.dns[0-9]+\]: \[[^]]+\]'; }
    snooze() { sleep $1 & nap=$!; wait $nap; nap=; }
    netwait() {
        fresh=$1
        online || { fresh=1; say "no network yet (no resolver known): the start waits for it"; }
        until online; do snooze $POLL; wanted || return 1; done
        [ -z "$fresh" ] || snooze $NET_SETTLE
        wanted
    }
    # The system clock set from the network by the bridge's binary, as root with the firewall's group: one line in
    # the log, never more than CLOCK_WAIT seconds
    clock() {
        clock_at=$(up)
        unsafe > /dev/null && return 0
        $RUNAS root $AS_GROUPS $BIN clock sync < /dev/null > $CLOCK_OUT 2> /dev/null &
        c=$! i=0
        while kill -0 $c 2>/dev/null; do
            [ $i -lt $CLOCK_WAIT ] || { kill -KILL $c 2>/dev/null; wait $c 2>/dev/null; rm -f $CLOCK_OUT; say "clock: no answer within $CLOCK_WAIT s, left as it is"; return 0; }
            sleep 1; i=$((i + 1))
        done
        wait $c 2>/dev/null
        said=$(head -n 1 $CLOCK_OUT 2>/dev/null | tr -cd 'A-Za-z0-9_=:. -' | cut -c1-100); rm -f $CLOCK_OUT
        case "$said" in
        "clock: "*action=set) hwclock -w -u 2>/dev/null; say "$said";;
        "clock: "*) say "$said";;
        *) say "clock: not set ($BIN has no clock sync?)";;
        esac
    }
    park() { [ -z "$parked" ] || return 0; say "$1"; parked=1; echo "$boot" > $PARK; }
    unpark() { parked=; rm -f $PARK; }
    # One start, the installer's: the layout checked, private/run/ made afresh with its gate and FIFO, launch.sh in a
    # session of its own, and the gate seen taken.  Fails when it is not for a retry to mend (parked) or when the
    # launcher never ran (`finished` left for the loop, which waits and tries again).
    launch() {
        if why=$(unsafe); then park "not started: $why (echo-install.sh start puts the layout right)"; return 1; fi
        [ -n "$clock_at" ] && [ $(( $(up) - clock_at )) -lt $GOOD_RUN ] || clock
        i=0 locked=1
        until mkdir $LOCK 2>/dev/null; do
            [ $i -lt $LOCK_WAIT ] || { locked=; say "$LOCK held for $LOCK_WAIT s (an installer that never finished?): starting without it"; break; }
            sleep 1; i=$((i + 1))
        done
        # what the bridge said before: one old part kept, moved away while no bridge writes to it
        if ! as_bridge "umask 077; cd $PRIV || exit 1
rm -rf run || exit 1
if [ -f bridge.log ] && [ \"\$(wc -c < bridge.log)\" -gt $OUT_MAX ]; then mv -f bridge.log bridge.log.1; fi
mkdir run && mkdir run/control && mkfifo run/stdin"; then
            [ -z "$locked" ] || rmdir $LOCK 2>/dev/null
            park "not started: $AS_USER cannot make $RUN"; return 1
        fi
        t0=$(up) missing=0
        setsid $RUNAS $AS_USER $AS_GROUPS $SH -c "umask 077; exec $SH $LAUNCH < /dev/null >> $OUT 2>&1" < /dev/null > /dev/null 2>&1 &
        i=0
        while [ -d $RUN/control ] && [ $i -lt $START_WAIT ]; do sleep 1; i=$((i + 1)); done
        [ -z "$locked" ] || rmdir $LOCK 2>/dev/null
        if [ -d $RUN/control ]; then
            # the gate taken back, so a launcher that comes late cannot pass it
            as_bridge "rmdir $RUN/control && touch $RUN/finished"
            say "$LAUNCH did not start within $START_WAIT s"; return 1
        fi
        say "started as $AS_USER ($LAUNCH), what it says is in $OUT"
    }
    # The launcher's last word where it ended without it: no bridge, no launcher, so what `finished` says is true
    settle() { [ -e $RUN/finished ] || [ -d $RUN/control ] || running || launcher || as_bridge "touch $RUN/finished"; }
    # It ended and nobody asked: the wait, then a start, unless its owner stepped in meanwhile
    again() {
        ran=$(( $(up) - t0 ))
        [ $ran -lt $GOOD_RUN ] || delay=$BACKOFF_MIN
        say "$1 after $ran s, restart in $delay s"
        sleep $delay &
        nap=$!; wait $nap; nap=
        if [ $ran -lt $GOOD_RUN ]; then
            delay=$((delay * 2)); [ $delay -le $BACKOFF_MAX ] || delay=$BACKOFF_MAX
        fi
        wanted || return 0
        netwait "" || return 0
        if [ -d $RUN ] && [ ! -e $RUN/stop ] && [ ! -d $RUN/control ] && ! running; then launch; fi
    }

    [ -z "$boot" ] || [ "$(cat $PARK 2>/dev/null)" != "$boot" ] || parked=1
    if running; then
        if [ -d $RUN ] && [ ! -e $RUN/stop ] && [ ! -e $RUN/finished ] && [ ! -d $RUN/control ]; then
            unpark; say "a bridge runs already: watched from here"
        else
            park "an echo-bridge runs that $LAUNCH did not start: left alone, none started"
        fi
    elif [ -n "$parked" ]; then
        say "stopped by its owner in this boot: not started (echo-install.sh start or bridge.sh start does)"
    else
        # whatever private/run/ holds is from before this boot, or from a bridge that is gone; a bridge that runs
        # after the wait is the installer's, started meanwhile, and is watched
        netwait first && { running || launch; }
    fi
    while wanted; do
        sleep $POLL
        [ -n "$parked" ] || { [ -n "$clock_at" ] && [ $(( $(up) - clock_at )) -lt $CLOCK_EVERY ]; } || clock
        if [ ! -d $RUN ]; then
            park "stopped by its owner ($RUN is gone): not started again"
        elif [ -e $RUN/stop ]; then
            park "stopped by its owner: not started again"
            settle
        elif [ -n "$parked" ]; then
            # the installer's start is the way back: its bridge running, its gate taken
            if [ ! -e $RUN/finished ] && [ ! -d $RUN/control ] && running; then
                unpark; t0=$(up) missing=0 delay=$BACKOFF_MIN
                say "started by its owner: watched from here"
            fi
        elif [ -e $RUN/finished ]; then
            again "exited"
        elif [ -d $RUN/control ]; then
            :           # a start under way that is not ours (ours wait for their gate): the installer's
        elif running; then
            missing=0
        elif launcher; then
            missing=0   # between the gate and the bridge, or between the bridge and `finished`
        else
            # no `finished`, no bridge and no launcher: it ended without its last word.  Twice in a row, so not a
            # look that fell between two of them.
            missing=$((missing + 1))
            [ $missing -lt 2 ] || { missing=0; settle; again "gone"; }
        fi
    done
    [ "$(cat $SUP 2>/dev/null)" != $$ ] || rm -f $SUP
    say "$LAUNCH or $CONF is gone: supervisor ended"
    ;;
stop)
    [ ! -L $BR ] && [ ! -L $PRIV ] && [ ! -L $RUN ] || { echo "bridge: $RUN is behind a link, nothing done"; exit 1; }
    [ -x $RUNAS ] || { echo "bridge: no $RUNAS"; exit 1; }
    [ -d $RUN ] || { echo "bridge: not running"; exit 0; }
    i=0
    until mkdir $LOCK 2>/dev/null; do       # a start under way holds it until its gate is taken
        [ $i -lt $START_WAIT ] || { echo "bridge: $LOCK is held (echo-install.sh at work?), try again"; exit 1; }
        sleep 1; i=$((i + 1))
    done
    trap 'rmdir $LOCK 2>/dev/null' EXIT
    # the installer's stop: the gate of a start not yet under way taken, or the launcher asked to close the input
    as_bridge "if rmdir $RUN/control 2>/dev/null; then touch $RUN/finished; else touch $RUN/stop; fi"
    i=0
    until [ -e $RUN/finished ]; do
        [ $i -lt $STOP_WAIT ] || break
        running || launcher || break        # ended without its last word
        sleep 1; i=$((i + 1))
    done
    if running; then echo "bridge: did not stop within $STOP_WAIT s; no process was signalled"; exit 1; fi
    as_bridge "rm -rf $RUN"
    b=$(boot_id); [ -z "$b" ] || echo "$b" > $PARK
    echo "bridge: stopped"
    ;;
start)
    wanted || { echo "bridge: no $LAUNCH or no $CONF, nothing to start"; exit 0; }
    halt                # first, so that the one that waits cannot say "stopped" once more
    rm -f $PARK
    setsid $SH "$0" run < /dev/null >> $LOG 2>&1 &
    echo "bridge: starting, see $LOG"
    ;;
*)
    echo "usage: bridge.sh run|stop|start"; exit 2
    ;;
esac
