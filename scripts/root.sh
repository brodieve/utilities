#!/bin/sh
#
# root.sh
#
# Ask Privileges for admin rights, with a one-sentence Buddhist, philosophical
# reason written by Claude Haiku. Install it on PATH as `root`.
#
#   root                          # admin rights, with a generated reason
#   root updating Homebrew        # the reason is written around this
#   root -n                       # print a reason without asking for rights
#   root -r                       # hand admin rights back
#
# The claude call is kept as small as it goes without an API key: no tools,
# MCP servers, skills, settings, CLAUDE.md or saved session, a system prompt
# of one line, and low effort so Haiku answers without thinking.
#
# POSIX sh, macOS only.
#
# v1.0 - brodieve - initial
#

set -eu

PRIVILEGES_CLI=/Applications/Privileges.app/Contents/MacOS/PrivilegesCLI
MODEL="${ROOT_MODEL:-claude-haiku-5-5}"
MAX_WORDS=20
# Used when claude is missing, fails, or will not keep to one short sentence.
FALLBACK_REASON='All privileges are impermanent; I take these rights lightly and will return them.'
# The teaching each reason draws on, one picked at random.
TOPICS='impermanence (anicca)
non-self (anatta)
suffering and its cessation (dukkha)
the Middle Way
non-attachment
dependent origination
right action from the Noble Eightfold Path
emptiness (sunyata)
mindfulness
beginner'"'"'s mind
compassion (karuna)
letting go'

usage() {
    cat <<'EOF'
Usage: root [-n] [PURPOSE...]
       root -r

Ask Privileges for admin rights, with a one-sentence Buddhist, philosophical
reason of 20 words or less written by Claude Haiku.

  root               ask for admin rights with a generated reason
  root PURPOSE...    the same, with the reason written around PURPOSE

Options:
  -n, --dry-run   Print a reason and stop, without asking for rights.
  -r, --remove    Hand admin rights back.
  -h, --help      Show this help.

Environment:
  ROOT_MODEL   the model that writes the reason (default claude-haiku-5-5)
EOF
}

note()        { printf 'root: %s\n' "$*" >&2; }
die()         { note "$*"; exit 1; }
usage_error() { note "$*"; printf 'Try root --help.\n' >&2; exit 2; }
have()        { command -v "$1" >/dev/null 2>&1; }

# Print a one-sentence reason for admin rights, built around $* if given.
ask_claude() {
    # Haiku settles on the same few answers, so pick the teaching here.
    topic=$(printf '%s\n' "$TOPICS" | awk 'BEGIN { srand() } NF { t[++n] = $0 }
        END { print t[int(rand() * n) + 1] }')
    if [ $# -gt 0 ]; then
        prompt="Write a Buddhist, philosophical reason a developer needs temporary admin rights on their Mac for: $*. Draw on $topic."
    else
        prompt="Write a Buddhist, philosophical reason a developer needs temporary admin rights on their Mac. Draw on $topic."
    fi
    # Run from / so no project CLAUDE.md or settings can be picked up.
    (cd / && claude -p \
        --model "$MODEL" \
        --effort=low \
        --tools '' \
        --strict-mcp-config \
        --disable-slash-commands \
        --setting-sources '' \
        --no-session-persistence \
        --system-prompt "Reply with one short plain sentence of 8 to 12 words, ending with a period, in the calm voice of a Buddhist teacher. No quotes, markdown or preamble." \
        "$prompt") </dev/null 2>/dev/null
}

# Print a reason, falling back to a fixed one rather than fail.
make_reason() {
    if have claude; then
        tries=0
        while [ "$tries" -lt 2 ]; do
            tries=$((tries + 1))
            # Keep the first line, without wrapping quotes or surrounding space.
            reason=$(ask_claude "$@" | sed -n '/[^[:space:]]/{
                s/^[[:space:]"'\'']*//
                s/[[:space:]"'\'']*$//
                p
                q
            }') || continue
            words=$(printf '%s\n' "$reason" | wc -w | tr -d ' ')
            if [ "$words" -ge 3 ] && [ "$words" -le "$MAX_WORDS" ]; then
                printf '%s\n' "$reason"
                return 0
            fi
        done
        note "claude did not give a usable reason; using the fallback"
    else
        note "claude not found; using the fallback reason"
    fi
    printf '%s\n' "$FALLBACK_REASON"
}

# ---------------------------------------------------------------- arguments

DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)    usage; exit 0 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -r|--remove)  [ $# -eq 1 ] || usage_error "$1 takes no arguments"
                      [ -x "$PRIVILEGES_CLI" ] || die "Privileges not found at $PRIVILEGES_CLI"
                      exec "$PRIVILEGES_CLI" --remove ;;
        --)           shift; break ;;
        -*)           usage_error "unknown option: $1" ;;
        *)            break ;;
    esac
done

if [ "$DRY_RUN" -eq 1 ]; then
    make_reason "$@"
    exit 0
fi

[ -x "$PRIVILEGES_CLI" ] || die "Privileges not found at $PRIVILEGES_CLI"

if dseditgroup -o checkmember -m "$(id -un)" admin >/dev/null 2>&1; then
    note "already an admin"
    exit 0
fi

REASON=$(make_reason "$@")
note "reason: $REASON"
exec "$PRIVILEGES_CLI" --add --reason "$REASON"
