#!/bin/sh
#
# Packages a built pasteshot into a release tarball and its checksum.
#
#     ./package.sh VERSION [binary-path]
#
# Writes swift/dist/pasteshot-VERSION-macos-universal.tar.gz and .sha256.

set -eu

version=${1:?usage: package.sh VERSION [binary-path]}
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
binary=${2:-"$here/build/pasteshot"}

if [ ! -f "$binary" ]; then
    echo "package.sh: no binary at $binary — run build.sh first" >&2
    exit 1
fi

name="pasteshot-${version}-macos-universal"
dist="$here/dist"
stage="$dist/$name"

rm -rf "$stage"
mkdir -p "$stage"

cp "$binary" "$stage/pasteshot"
cp "$here/README.md" "$stage/README.md"
cp "$here/../LICENSE" "$stage/LICENSE"

# Without COPYFILE_DISABLE, bsdtar packs an ._ AppleDouble beside every file.
COPYFILE_DISABLE=1 tar -C "$dist" -czf "$dist/$name.tar.gz" "$name"
rm -rf "$stage"

# Checksum with a bare filename inside, so `shasum -c` works from the dist
# directory after downloading.
(cd "$dist" && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")

echo "package.sh: wrote $dist/$name.tar.gz"
