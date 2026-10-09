#!/bin/sh
#
# nosleep.sh
#
# Keep the Mac awake for a while, or for as long as a command runs, with a
# time limit either way. It turns system sleep off outright with
# `pmset disablesleep 1`, so closing the lid does not sleep it either, on
# battery or without an external display. Install it on PATH as `nosleep`.
#
#   nosleep                       # 60m, in the background
#   nosleep -t 2h                 # 2h, in the background
#   nosleep -c make build         # while make runs, for at most 60m
#   nosleep -t 3h -c make build   # while make runs, for at most 3h
#   nosleep -t 3h make build      # -c is optional
#
# How the pieces fit:
#
#   - A caffeinate process owned by you is the session's lease. It ends at the
#     time limit, when the command exits (-w), or when you kill it.
#   - pmset needs root, so a root guard started once through sudo turns sleep
#     off, waits for the lease to end, and turns sleep back on. It never needs
#     sudo again, so it outlives Privileges' admin expiry and screen-lock
#     revocation.
#   - Overlapping sessions are counted: sleep comes back only when the last
#     lease ends, and to whatever disablesleep was before the first one.
#
# POSIX sh, macOS only.
# 
# v1.0 - brodieve - initial
#

set -eu

DURATION='60m'
FLAGS="${NOSLEEP_FLAGS:--i}"
ARGC=$#

STATE_DIR=/var/db/nosleep
PRIVILEGES_CLI=/Applications/Privileges.app/Contents/MacOS/PrivilegesCLI
# Privileges may require a reason and check it reads as a sentence; this one
# also sits inside the 20-50 character bounds its sample profile uses.
PRIVILEGES_REASON='Run pmset to keep the Mac awake with lid closed'

usage() {
    cat <<'EOF'
Usage: nosleep [-t DURATION] [[-c] COMMAND [ARG...]]

Keep the Mac from sleeping for a while, or while a command runs, with the
lid open or closed.

  nosleep                    prevent sleep for 60m, in the background
  nosleep -t 2h              prevent sleep for 2h, in the background
  nosleep -c COMMAND         run COMMAND, preventing sleep until it exits
                             or 60m pass, whichever is first
  nosleep -t 2h -c COMMAND   the same, for up to 2h
  nosleep -t 2h COMMAND      -c is optional

Options:
  -t, --time DURATION   The longest to hold off sleep (default 60m). Units
                        s, m, h and d, alone or combined: 90s, 45m, 2h,
                        1h30m. A bare number is minutes.
  -c, --command CMD...  Run CMD, preventing sleep while it runs. Everything
                        after -c is the command, so it goes last. A single
                        quoted argument runs in $SHELL, so pipes and && work:
                        nosleep -c 'make && say done'
  -h, --help            Show this help.

Sleep is turned off with `pmset disablesleep 1`, which takes root: each
session runs sudo once, and a standard user is first given admin rights by
Privileges, which are handed back as soon as sudo is done.

Reaching the time limit only lets the Mac sleep again; the command keeps
running. The background forms print a pid; kill it to stop early.

Environment:
  NOSLEEP_FLAGS   caffeinate assertion flags for the session (default -i).
                  -di keeps the display on as well.

Exit codes:
  0    sleep turned off for a background session
  1    error
  2    bad usage
       with a command, the command's own exit status
EOF
}

note()        { printf 'nosleep: %s\n' "$*" >&2; }
die()         { note "$*"; exit 1; }
usage_error() { note "$*"; printf 'Try nosleep --help.\n' >&2; exit 2; }
have()        { command -v "$1" >/dev/null 2>&1; }

# Print DURATION (90s, 45m, 2h, 1h30m, or bare minutes) as seconds.
to_seconds() {
    rest=$1
    total=0
    case "$rest" in
        ''|*[!0-9]*) ;;
        *) rest="${rest}m" ;;
    esac
    [ -n "$rest" ] || return 1
    while [ -n "$rest" ]; do
        num=${rest%%[!0-9]*}
        rest=${rest#"$num"}
        unit=${rest%"${rest#?}"}
        rest=${rest#?}
        [ -n "$num" ] || return 1
        # Drop leading zeros, or sh arithmetic reads 08 as a bad octal.
        num=${num#"${num%%[!0]*}"}
        num=${num:-0}
        case "$unit" in
            s) total=$((total + num)) ;;
            m) total=$((total + num * 60)) ;;
            h) total=$((total + num * 3600)) ;;
            d) total=$((total + num * 86400)) ;;
            *) return 1 ;;
        esac
    done
    [ "$total" -gt 0 ] || return 1
    printf '%s\n' "$total"
}

# Print seconds as 1h30m, 45m, 90s...
fmt_duration() {
    h=$(($1 / 3600)) m=$(($1 % 3600 / 60)) s=$(($1 % 60))
    out=''
    [ "$h" -eq 0 ] || out="${h}h"
    [ "$m" -eq 0 ] || out="${out}${m}m"
    [ "$s" -eq 0 ] || out="${out}${s}s"
    printf '%s\n' "$out"
}

# Print the wall-clock time $1 seconds from now.
clock_after() {
    end=$(($(date +%s) + $1))
    if [ "$1" -lt 86400 ]; then
        date -r "$end" '+%H:%M'
    else
        date -r "$end" '+%a %d %b %H:%M'
    fi
}

# Start caffeinate in the background, passing any extra arguments through.
# It ignores the terminal's signals, so it ends only at the time limit, when
# the -w process exits, or when killed: closing the terminal does not cut the
# background forms short, and a ^C or ^Z the command survives does not
# release sleep early.
spawn_caffeinate() {
    trap '' HUP INT QUIT TSTP
    # shellcheck disable=SC2086 # FLAGS is split into separate flags on purpose
    caffeinate $FLAGS -t "$SECS" "$@" </dev/null >/dev/null 2>&1 &
}

# --------------------------------------------------------------- root guard
#
# Runs as root, as `sudo sh nosleep --root-guard LEASE_PID SECONDS`. Session
# bookkeeping lives in $STATE_DIR, which survives a reboot just as the
# disablesleep setting does, so a session cut off by a crash or power loss
# is still accounted for by the next one:
#
#   lease.PID  one per live session, holding its lease's start time so a
#              recycled pid does not pass for the lease
#   prior      disablesleep as it was before the first live session
#   lock       mkdir lock guarding both

sleep_disabled() { pmset -g | awk '$1 == "SleepDisabled" { print $2 }'; }

lock() {
    tries=0
    until mkdir "$STATE_DIR/lock" 2>/dev/null; do
        # What it guards takes milliseconds; a lock held this long belongs to
        # a process that died holding it.
        tries=$((tries + 1))
        [ "$tries" -lt 50 ] || rmdir "$STATE_DIR/lock" 2>/dev/null || true
        sleep 0.2
    done
}
unlock() { rmdir "$STATE_DIR/lock"; }

# Drop the files of leases that have ended; succeed if any are still live.
live_leases() {
    found=1
    for f in "$STATE_DIR"/lease.*; do
        [ -e "$f" ] || continue
        started=$(cat "$f")
        if [ -n "$started" ] &&
           [ "$(ps -o lstart= -p "${f##*/lease.}" 2>/dev/null)" = "$started" ]; then
            found=0
        else
            rm -f "$f"
        fi
    done
    return "$found"
}

# End lease $1's session, turning sleep back on if it was the last. Several
# sessions can end at once; the first to find no live lease restores prior
# and removes it, so the rest find nothing owed.
release() {
    lock
    rm -f "$STATE_DIR/lease.$1"
    if ! live_leases && [ -f "$STATE_DIR/prior" ]; then
        prior=$(cat "$STATE_DIR/prior")
        [ "$prior" = 1 ] || prior=0
        pmset -a disablesleep "$prior" >/dev/null && rm -f "$STATE_DIR/prior"
    fi
    unlock
}

root_guard() {
    lease=$1 secs=$2
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    [ "$(id -u)" -eq 0 ] || die "--root-guard must run as root"
    # A ^C from here on must not strand sleep turned off with nothing left
    # to turn it back on.
    trap '' HUP INT QUIT TSTP

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    lock

    started=$(ps -o lstart= -p "$lease" 2>/dev/null) || started=''
    if [ -z "$started" ]; then
        unlock
        die "the session ended before sleep could be turned off"
    fi

    # With no live session, a prior file left behind is from one that was cut
    # off before it could restore, and it still holds the true original.
    if ! live_leases && [ ! -f "$STATE_DIR/prior" ]; then
        was=$(sleep_disabled)
        [ "$was" != 1 ] ||
            note "sleep was already turned off (pmset disablesleep 1) and will stay off afterwards"
        printf '%s\n' "$was" > "$STATE_DIR/prior"
    fi

    pmset -a disablesleep 1 >/dev/null || true
    if [ "$(sleep_disabled)" != 1 ]; then
        unlock
        die "pmset did not turn sleep off"
    fi
    printf '%s\n' "$started" > "$STATE_DIR/lease.$lease"

    # Wait for the lease to end, then release. The extra -t is a backstop
    # should the lease be stopped with SIGSTOP and never reach its own. TERM,
    # as at logout, ends the wait early rather than skipping the release.
    #
    # Job control is on just for this spawn so the watcher gets a process
    # group of its own: sudo runs us in a pty of its own and whatever it
    # does to our group on the way out must not reach the watcher.
    set -m 2>/dev/null || true
    (
        set +m
        trap '' HUP INT QUIT TSTP
        caffeinate -t "$secs" -w "$lease" &
        waiter=$!
        trap 'kill "$waiter" 2>/dev/null' TERM
        wait "$waiter" || true
        release "$lease"
    ) </dev/null >/dev/null 2>&1 &
    set +m

    unlock
}

if [ "${1:-}" = --root-guard ]; then
    case "${2:-}:${3:-}" in
        *[!0-9:]*|:*|*:) die "usage: nosleep --root-guard LEASE_PID SECONDS" ;;
    esac
    root_guard "$2" "$3"
    exit 0
fi

# ---------------------------------------------------------------- arguments

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)    usage; exit 0 ;;
        -t|--time)    [ $# -ge 2 ] || usage_error "$1 needs a duration, e.g. $1 45m"
                      DURATION=$2; shift 2 ;;
        -c|--command) [ $# -ge 2 ] || usage_error "$1 needs a command"
                      shift; break ;;
        --)           shift; break ;;
        -*)           usage_error "unknown option: $1" ;;
        *)            break ;;
    esac
done

SECS=$(to_seconds "$DURATION") ||
    usage_error "invalid duration: $DURATION (try 90s, 45m, 2h or 1h30m)"

for flag in $FLAGS; do
    case "$flag" in
        -|-*[!dimsu]*|[!-]*)
            die "NOSLEEP_FLAGS takes caffeinate's -d -i -m -s -u flags, not: $flag" ;;
    esac
done

for tool in caffeinate pmset; do
    have "$tool" || die "$tool not found; nosleep only works on macOS"
done

if [ $# -gt 1 ] && ! have "$1"; then
    note "command not found: $1"
    exit 127
fi

# -------------------------------------------------------------------- lease

# With a command, caffeinate watches this shell's pid, which exec hands to
# the command, and lets go when the command exits or the time is up,
# whichever comes first. Starting it from a subshell that exits straight away
# leaves it parented to launchd rather than as a stray child the command
# might reap.
if [ $# -eq 0 ]; then
    lease=$(spawn_caffeinate; echo "$!")
else
    lease=$(spawn_caffeinate -w $$; echo "$!")
fi

# ------------------------------------------------------------- root access

granted=0

revoke_admin() {
    [ "$granted" -eq 1 ] || return 0
    granted=0
    "$PRIVILEGES_CLI" --remove >&2 ||
        note "could not hand back admin rights; Privileges will expire them"
}

# Undo the setup so far. Ending the lease is enough on the root side: if the
# guard got as far as turning sleep off, it turns it back on when it sees the
# lease go.
abort() {
    kill "$lease" 2>/dev/null || true
    revoke_admin
}
fail() { abort; die "$*"; }

trap 'abort; exit 129' HUP
trap 'abort; exit 130' INT
trap 'abort; exit 143' TERM

if [ -x "$PRIVILEGES_CLI" ] &&
   ! dseditgroup -o checkmember -m "$(id -un)" admin >/dev/null 2>&1; then
    note "asking Privileges for admin rights, to run pmset through sudo"
    # Set first, so a ^C landing just after the grant still hands it back.
    granted=1
    "$PRIVILEGES_CLI" --add --reason "$PRIVILEGES_REASON" >&2 ||
        fail "Privileges did not grant admin rights"
fi

sudo /bin/sh "$0" --root-guard "$lease" "$SECS" >&2 ||
    fail "could not turn sleep off with pmset"

revoke_admin
trap - HUP INT TERM

# ---------------------------------------------------------- background form

if [ $# -eq 0 ]; then
    [ "$ARGC" -gt 0 ] || note "see nosleep -h or --help for options"
    note "sleep is off for $(fmt_duration "$SECS"), until $(clock_after "$SECS") (pid $lease; kill $lease to stop early)"
    exit 0
fi

# ------------------------------------------------------------- command form

note "sleep is off while the command runs, for up to $(fmt_duration "$SECS") (until $(clock_after "$SECS"))"

if [ $# -eq 1 ]; then
    exec "${SHELL:-/bin/sh}" -c "$1"
fi
exec "$@"
