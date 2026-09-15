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

### Build

```sh
swiftc -O -whole-module-optimization -o /usr/local/bin/pasteshot swift/pasteshot.swift
```

Or take the universal binary that CI builds: the **swift** workflow compiles
`arm64` and `x86_64` slices on every push touching `swift/`, `lipo`s them
together, ad-hoc signs the result and uploads it as the `pasteshot-universal`
artifact. Download it from the run's summary page.

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
