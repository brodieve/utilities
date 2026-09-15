# swift

## pasteshot.swift

Pastes the most recent screenshot into the frontmost application as PNG image
data, then puts the original clipboard back.

Screenshots land on the Desktop (or wherever `com.apple.screencapture location`
points) and getting one into Slack or a browser normally means dragging the
file, which sends it as a named attachment rather than an inline image.
`pasteshot` finds the newest capture, writes it to the pasteboard as bare
`public.png` data — the same thing "Copy Image" produces — synthesises
Command-V, then restores whatever was on the clipboard before. Bind it to a
hotkey and a screenshot pastes the way an image should.

### Install

Grab the latest [release](https://github.com/brodieve/utilities/releases?q=pasteshot)
— a universal (arm64 + x86_64) build for macOS 13 and later:

```sh
tar xzf pasteshot-VERSION-macos-universal.tar.gz
cd pasteshot-VERSION-macos-universal
shasum -a 256 -c ../pasteshot-VERSION-macos-universal.tar.gz.sha256
xattr -d com.apple.quarantine pasteshot
install -m 755 pasteshot /usr/local/bin/pasteshot
```

The binary is ad-hoc signed rather than notarised, so Gatekeeper refuses it
until the quarantine attribute is off.

### Build

```sh
swift/build.sh                      # swift/build/pasteshot, universal, signed
swift/package.sh 1.0.0              # swift/dist/*.tar.gz + .sha256
```

Or straight from the source, as the file header says:

```sh
swiftc -O -whole-module-optimization -o /usr/local/bin/pasteshot swift/pasteshot.swift
```

`build.sh` takes `DEPLOYMENT_TARGET` (default `13.0`) and `CODESIGN_IDENTITY`
(default `-`, ad-hoc). Sign with a real Developer ID instead if you want the
binary to survive a move between machines without re-granting Accessibility.

### Releasing

Two workflows, both running the scripts above so CI and releases cannot drift:

- **swift** builds on every push and pull request touching `swift/`, and
  uploads the tarball as an artifact.
- **pasteshot release** fires on a `pasteshot-v*` tag, builds, and publishes a
  GitHub release with the tarball and its checksum attached.

```sh
git tag pasteshot-v1.0.0
git push origin pasteshot-v1.0.0
```

Tags are scoped per utility so a future release of something else in this repo
cannot collide, and the generated notes are cut from the previous `pasteshot-v*`
tag rather than from whatever was tagged last. A version with a suffix —
`pasteshot-v1.1.0-rc.1` — is published as a prerelease.

### Usage

```
pasteshot               # copy the newest screenshot and paste it
pasteshot --copy-only   # copy only; no keystroke, clipboard keeps the image
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `PASTESHOT_RESTORE_DELAY_MS` | `250` | How long the image stays on the pasteboard before the previous clipboard is restored. |
| `PASTESHOT_MODIFIER_TIMEOUT_MS` | `1000` | How long to wait for physically-held modifiers to be released before posting Command-V. |

### Notes

- Requires macOS 13+ (`UnsafeRawPointer.loadUnaligned`).
- Synthesising Command-V needs Accessibility permission, and the grant attaches
  to whichever process TCC holds responsible — run from a shell or a hotkey
  launcher, that is Terminal or Raycast, not this binary; launched through
  LaunchServices it needs its own grant. `--copy-only` skips the keystroke and
  therefore the permission entirely.
- There is no restore delay that is correct for every app. Electron apps route
  paste through a JS layer and need longer than native ones; raise
  `PASTESHOT_RESTORE_DELAY_MS` if an image pastes as the old clipboard content.
- Restoring the clipboard reads every representation on it, which forces
  promised data to resolve. Content copied from an app that has since quit
  cannot survive that round trip.
- The directory scan uses `getattrlistbulk(2)` rather than Spotlight, so a
  capture is visible the instant it hits disk. HEIC/HEIF and JPEG captures are
  matched too, and transcoded to PNG through ImageIO with their DPI carried
  across so retina captures keep their intended display size.
