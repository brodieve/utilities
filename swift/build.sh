#!/bin/sh
#
# Builds a universal, ad-hoc signed pasteshot.
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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$(dirname -- "$out")"

# Apple silicon defaults to arm64, so x86_64 has to be asked for explicitly,
# and swiftc takes one -target at a time. Pinning the deployment target keeps
# an SDK bump from quietly producing a binary that will not run on macOS 13,
# which is the floor the source needs for loadUnaligned. (arch in arm64 x86_64)
for arch in arm64; do
    swiftc -O -whole-module-optimization \
        -target "${arch}-apple-macos${target}" \
        -o "$work/pasteshot-$arch" \
        "$here/pasteshot.swift"
done

lipo -create -output "$out" "$work/pasteshot-arm64" "$work/pasteshot-x86_64"

# lipo drops the per-slice signatures. Re-sign, so the binary keeps one stable
# code identity: TCC keys the Accessibility grant to it, and an unsigned
# rebuild is a different process as far as the permission list is concerned.
codesign --force --sign "$identity" --identifier com.brodieve.pasteshot "$out"

# otool rather than vtool: it walks both slices of a fat binary.
lipo -archs "$out"
codesign --verify --verbose "$out"
otool -l "$out" | grep -A4 LC_BUILD_VERSION

echo "build.sh: wrote $out"
