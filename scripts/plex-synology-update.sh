#!/bin/sh
#
# plex-synology-update.sh
#
# Download the latest Plex Media Server .spk for Synology DSM 7.2.2+ and
# install it with synopkg.
#
# Plex publishes its release manifest at https://plex.tv/api/downloads/5.json.
# DSM 7.2.2 and newer have their own entry in that manifest, distinct from the
# older "Synology (DSM 7)" packages; its releases carry distro "synology-dsm72".
# This script pulls that entry, picks the build matching the NAS architecture,
# verifies the published SHA-1, and hands the file to synopkg.
#
# Run as root on the NAS (SSH in, then `sudo -i`).
#
#   ./plex-synology-update.sh              # update if a newer version exists
#   ./plex-synology-update.sh --dry-run    # download + verify only
#   ./plex-synology-update.sh --token XXX  # use the Plex Pass channel
#
# POSIX sh: DSM's shells (ash/bash) both run this.

set -eu

MANIFEST_URL='https://plex.tv/api/downloads/5.json'
DISTRO='synology-dsm72'
PKG='PlexMediaServer'

ARCH=''
CHANNEL=''
TOKEN="${PLEX_TOKEN:-}"
DEST=''
DRY_RUN=0
FORCE=0
KEEP=0

WORK_FILE=''
SPK_FILE=''

usage() {
    cat <<'EOF'
Usage: plex-synology-update.sh [options]

Download the latest Plex Media Server package for Synology DSM 7.2.2+ and
install it via synopkg.

Options:
  -a, --arch ARCH     Package architecture: x86_64, aarch64, armv7neon.
                      Auto-detected from `uname -m` when omitted.
  -t, --token TOKEN   Plex token. Required for --channel plexpass.
                      Defaults to $PLEX_TOKEN.
  -c, --channel CH    "public" (default) or "plexpass" for early releases.
                      Implies --token.
  -d, --dest DIR      Directory to download into. Defaults to the first
                      writable of /volume1/@tmp, /var/services/tmp, /tmp.
  -n, --dry-run       Download and verify the package, but do not install.
  -f, --force         Install even if the running version already matches.
  -k, --keep          Keep the downloaded .spk instead of deleting it.
      --distro ID     Override the manifest distro id (default: synology-dsm72).
  -h, --help          Show this help.

Environment:
  PLEX_TOKEN          Same as --token.

Exit codes:
  0 success (installed, or already up to date)
  1 error
  2 bad usage
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ "$KEEP" -eq 0 ] && [ -n "$SPK_FILE" ] && [ -f "$SPK_FILE" ]; then
        rm -f "$SPK_FILE"
    fi
    [ -n "$WORK_FILE" ] && rm -f "$WORK_FILE" "$WORK_FILE.objects" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- arguments

while [ $# -gt 0 ]; do
    case "$1" in
        -a|--arch)    [ $# -ge 2 ] || die "$1 needs a value"; ARCH="$2";    shift 2 ;;
        -t|--token)   [ $# -ge 2 ] || die "$1 needs a value"; TOKEN="$2";   shift 2 ;;
        -c|--channel) [ $# -ge 2 ] || die "$1 needs a value"; CHANNEL="$2"; shift 2 ;;
        -d|--dest)    [ $# -ge 2 ] || die "$1 needs a value"; DEST="$2";    shift 2 ;;
        --distro)     [ $# -ge 2 ] || die "$1 needs a value"; DISTRO="$2";  shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -f|--force)   FORCE=1;   shift ;;
        -k|--keep)    KEEP=1;    shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; printf '\nerror: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

case "${CHANNEL:-public}" in
    public)   CHANNEL='' ;;
    plexpass) CHANNEL='plexpass'
              [ -n "$TOKEN" ] || die "--channel plexpass requires --token or \$PLEX_TOKEN" ;;
    *)        die "unknown channel: $CHANNEL (expected public or plexpass)" ;;
esac

# ------------------------------------------------------------- environment

have() { command -v "$1" >/dev/null 2>&1; }

if [ "$DRY_RUN" -eq 0 ]; then
    have synopkg || die "synopkg not found - run this on the Synology NAS itself"
    [ "$(id -u)" -eq 0 ] || die "must run as root (sudo -i), synopkg requires it"
fi

if have curl; then
    DOWNLOADER=curl
elif have wget; then
    DOWNLOADER=wget
else
    die "neither curl nor wget is available"
fi

# Fetch $1 into file $2.
fetch() {
    case "$DOWNLOADER" in
        curl) curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1" ;;
        wget) wget -q -O "$2" "$1" ;;
    esac
}

# Append query parameters to a URL, picking ? or & as needed.
url_param() {
    case "$1" in
        *\?*) printf '%s&%s' "$1" "$2" ;;
        *)    printf '%s?%s' "$1" "$2" ;;
    esac
}

# ------------------------------------------------------- architecture pick

if [ -z "$ARCH" ]; then
    machine=$(uname -m 2>/dev/null || echo unknown)
    case "$machine" in
        x86_64|amd64)          ARCH=x86_64 ;;
        aarch64|arm64|armv8*)  ARCH=aarch64 ;;
        armv7*|armv7l)         ARCH=armv7neon ;;
        *) die "cannot map '$machine' to a Plex build; pass --arch x86_64|aarch64|armv7neon" ;;
    esac
fi

case "$ARCH" in
    x86_64)    BUILD=linux-x86_64 ;;
    aarch64)   BUILD=linux-aarch64 ;;
    armv7neon) BUILD=linux-armv7neon ;;
    *) die "unknown arch: $ARCH (expected x86_64, aarch64 or armv7neon)" ;;
esac

# ------------------------------------------------------------ dest directory

if [ -z "$DEST" ]; then
    for candidate in /volume1/@tmp /var/services/tmp "${TMPDIR:-/tmp}" /tmp; do
        if [ -d "$candidate" ] && [ -w "$candidate" ]; then
            DEST="$candidate"
            break
        fi
    done
fi
[ -n "$DEST" ] || die "no writable download directory found; pass --dest DIR"
[ -d "$DEST" ] || die "download directory does not exist: $DEST"
[ -w "$DEST" ] || die "download directory is not writable: $DEST"

if have df; then
    free_kb=$(df -Pk "$DEST" 2>/dev/null | awk 'NR==2 {print $4}')
    case "$free_kb" in
        ''|*[!0-9]*) : ;;
        *) [ "$free_kb" -lt 512000 ] && warn "only $((free_kb / 1024)) MB free in $DEST" ;;
    esac
fi

# --------------------------------------------------------------- manifest

WORK_FILE="$DEST/.plex-manifest.$$"

manifest_url="$MANIFEST_URL"
[ -n "$CHANNEL" ] && manifest_url=$(url_param "$manifest_url" "channel=$CHANNEL")
[ -n "$TOKEN" ]   && manifest_url=$(url_param "$manifest_url" "X-Plex-Token=$TOKEN")

log "Fetching Plex release manifest..."
fetch "$manifest_url" "$WORK_FILE" || die "could not download the release manifest"
[ -s "$WORK_FILE" ] || die "the release manifest came back empty"

# Split the (single-line) JSON so every object sits on its own line. Each
# release object then carries its distro, build, url and checksum together,
# which is enough to pick the right one without a JSON parser - DSM ships
# neither jq nor python by default.
tr -d '\n' < "$WORK_FILE" | sed 's/{/\
{/g; s/}/}\
/g' > "$WORK_FILE.objects"

release=$(
    grep "\"distro\"[[:space:]]*:[[:space:]]*\"$DISTRO\"" "$WORK_FILE.objects" |
    grep "\"build\"[[:space:]]*:[[:space:]]*\"$BUILD\"" |
    head -n 1
) || true

if [ -z "$release" ]; then
    die "no '$BUILD' release found for distro '$DISTRO'.
Plex may have renamed the DSM 7.2.2+ entry; check $MANIFEST_URL and re-run
with --distro <id>."
fi

# Read a string field out of a one-line JSON object.
json_field() {
    printf '%s' "$1" |
        grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" |
        head -n 1 |
        sed 's/^[^:]*:[[:space:]]*"//; s/"$//'
}

SPK_URL=$(json_field "$release" url)
SPK_SHA1=$(json_field "$release" checksum)
VERSION=$(json_field "$release" version)

[ -n "$SPK_URL" ] || die "the manifest entry has no download url"
case "$SPK_URL" in
    https://*) : ;;
    *) die "refusing a non-https download url: $SPK_URL" ;;
esac
[ -n "$VERSION" ] || VERSION='unknown'

log "Latest for DSM 7.2.2+ ($ARCH): $VERSION"

# ------------------------------------------------------- installed version

INSTALLED=''
if have synopkg; then
    INSTALLED=$(synopkg version "$PKG" 2>/dev/null | tr -d '\r' | head -n 1) || INSTALLED=''
fi

if [ -n "$INSTALLED" ]; then
    log "Currently installed:            $INSTALLED"
else
    log "Currently installed:            (not installed)"
fi

# synopkg reports the version baked into the package INFO file, whose build
# suffix differs from the manifest's (1.43.3.10896-720010896 vs
# 1.43.3.10896-cb3ebc72d), so compare only the numeric part ahead of the dash.
version_base() { printf '%s' "${1%%-*}"; }

if [ -n "$INSTALLED" ] &&
   [ "$(version_base "$INSTALLED")" = "$(version_base "$VERSION")" ] &&
   [ "$FORCE" -eq 0 ]; then
    log "Already up to date. Use --force to reinstall."
    exit 0
fi

# --------------------------------------------------------------- download

SPK_FILE="$DEST/$(basename "$SPK_URL")"

log "Downloading $(basename "$SPK_URL")..."
fetch "$SPK_URL" "$SPK_FILE" || die "download failed: $SPK_URL"
[ -s "$SPK_FILE" ] || die "downloaded package is empty"

if [ -n "$SPK_SHA1" ]; then
    actual=''
    if have sha1sum; then
        actual=$(sha1sum "$SPK_FILE" | awk '{print $1}')
    elif have openssl; then
        actual=$(openssl dgst -sha1 "$SPK_FILE" | awk '{print $NF}')
    else
        warn "no sha1sum or openssl available - skipping checksum verification"
    fi

    if [ -n "$actual" ]; then
        if [ "$actual" != "$SPK_SHA1" ]; then
            die "checksum mismatch
  expected $SPK_SHA1
  got      $actual"
        fi
        log "Checksum OK (sha1 $SPK_SHA1)"
    fi
else
    warn "the manifest published no checksum - skipping verification"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    KEEP=1
    log "Dry run: package left at $SPK_FILE"
    log "Install it with: synopkg install '$SPK_FILE'"
    exit 0
fi

# ---------------------------------------------------------------- install

WAS_RUNNING=0
if [ -n "$INSTALLED" ]; then
    if synopkg is_onoff "$PKG" >/dev/null 2>&1; then
        WAS_RUNNING=1
        log "Stopping $PKG..."
        synopkg stop "$PKG" >/dev/null || warn "could not stop $PKG; continuing"
    fi
fi

log "Installing $VERSION..."
if ! synopkg install "$SPK_FILE"; then
    if [ "$WAS_RUNNING" -eq 1 ]; then
        warn "install failed - restarting the previous version"
        synopkg start "$PKG" >/dev/null 2>&1 || true
    fi
    die "synopkg install failed"
fi

log "Starting $PKG..."
synopkg start "$PKG" >/dev/null || warn "could not start $PKG; start it from Package Center"

NOW=$(synopkg version "$PKG" 2>/dev/null | tr -d '\r' | head -n 1) || NOW=''
log "Done. Plex Media Server is now ${NOW:-$VERSION}."
