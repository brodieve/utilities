#!/bin/sh
#
# Builds an arm64, ad-hoc signed pasteshot.
#
#     ./build.sh [output-path]        # default: swift/build/pasteshot
#
# Environment:
#     DEPLOYMENT_TARGET   minimum macOS version (default 13.0)
#     CODESIGN_IDENTITY   codesign identity (default "-", ad-hoc)

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=${1:-"$here/build/pasteshot"}
target=${DEPLOYMENT_TARGET:-13.0}
identity=${CODESIGN_IDENTITY:--}

if [ "$(uname -s)" != Darwin ]; then
    echo "build.sh: AppKit and getattrlistbulk(2) are macOS-only" >&2
    exit 1
fi

mkdir -p "$(dirname -- "$out")"

# arm64 only: Intel Macs are past the point of being worth a second slice.
# Pinning the deployment target keeps an SDK bump from quietly producing a
# binary that will not run on macOS 13, which is the floor the source needs
# for loadUnaligned.
swiftc -O -whole-module-optimization \
    -target "arm64-apple-macos${target}" \
    -o "$out" \
    "$here/pasteshot.swift"

# Sign, so the binary keeps one stable code identity: TCC keys the
# Accessibility grant to it, and an unsigned rebuild is a different process as
# far as the permission list is concerned.
codesign --force --sign "$identity" --identifier com.brodieve.pasteshot "$out"

lipo -archs "$out"
codesign --verify --verbose "$out"
otool -l "$out" | grep -A4 LC_BUILD_VERSION

echo "build.sh: wrote $out"
