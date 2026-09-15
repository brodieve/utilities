#!/bin/sh
#
# Installs pasteshot into ~/.local/bin, building first if needed.
#
#     ./install.sh [install-dir]      # default: ~/.local/bin
#
# Environment:
#     PASTESHOT_BIN   binary to install (default: swift/build/pasteshot)

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bindir=${1:-"$HOME/.local/bin"}
binary=${PASTESHOT_BIN:-"$here/build/pasteshot"}
source="$here/pasteshot.swift"

# Rebuild when there is nothing to install, or when the source has moved on
# since the last build. `-nt` is false for equal mtimes, which is what we want.
if [ ! -f "$binary" ] || [ "$source" -nt "$binary" ]; then
    echo "install.sh: building $binary"
    "$here/build.sh" "$binary"
else
    echo "install.sh: reusing $binary"
fi

mkdir -p "$bindir"

# Install to a temporary name and rename over the old binary: an atomic replace
# leaves no window where a running shell finds a half-written file, and it
# breaks the hardlink rather than writing through it.
tmp="$bindir/.pasteshot.$$"
cp "$binary" "$tmp"
chmod 755 "$tmp"
mv -f "$tmp" "$bindir/pasteshot"

echo "install.sh: installed $bindir/pasteshot"

case ":$PATH:" in
    *":$bindir:"*) ;;
    *) echo "install.sh: note — $bindir is not on your PATH" >&2 ;;
esac

