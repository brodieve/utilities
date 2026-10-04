# Parking

An iPhone app for visitor parking passes on [Pass10x](https://www.pass10x.com).
Each saved guest (a plate and a short name) is a button; tap one and it
becomes the suite's active 24 hour pass, cancelling any other active pass
first. **+** saves a new guest, and can create its pass straight away.
Touch and hold a guest to remove it. The **X** on the active pass revokes it.

<img src="Parking/Assets.xcassets/Logo.imageset/Logo.png" width="96" alt="">

## How it works

Pass10x has no API to call, so the app does what a person does in the
resident web app, in a web view kept behind the screen:

- **Log in:** pick the building on the home page, enter the suite, choose
  **RESIDENT**, enter the password. Going straight to `/signin` skips the
  RESIDENT choice and the login is refused.
- **Buttons:** **Manage Parking → Previously Parked Plates**, each with the
  name saved in its collapsed details. They are cached, so they show at once
  on launch while the app checks the site.
- **Tap a button:** cancel any other row in **Active Visitor Parking
  Passes**, then press that plate's **Create** button, which opens the pass
  form filled in, and submit it. If another pass is active the app asks first,
  since only one pass is allowed per suite.
- **Revoke** (the X on the active pass): after the app asks, press that
  pass's delete button in **Active Visitor Parking Passes** and confirm the
  site's "Delete This Parking Pass?" dialog. It works for any active pass,
  including one made on the website for a plate that is not saved.
- **+:** **Setup a Visitor Pass → Save Visitor**, then the same as a tap if
  "Create pass now" is on.
- **Remove Guest** (touch and hold a button): after the app asks, press the
  trash icon in that plate's row of **Previously Parked Plates** and confirm
  the site's dialog. Only a row whose plate matches exactly is touched; if
  there is none, or more than one, it stops with an error. A guest with the
  active pass cannot be removed until the pass ends or is revoked, so the
  pass is never cancelled as a side effect.

The app presses a saved plate's trash icon only to remove that guest, and
never presses the edit icon. It cancels a pass only when you revoke it, or
when you tap another guest and confirm replacing it. All of the page work is in
[`Parking/pass10x.js`](Parking/pass10x.js); `PassEngine.swift` loads pages
and calls its steps one at a time. If Pass10x changes its pages, **Settings →
Show browser** shows where a step gets stuck.

The building, suite and password are kept in the app's Keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). The site's own
"Remember Me" is switched off at login, so the password is not also left in
the web view's storage.

## Build

Needs Xcode 15 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd ios/Parking
xcodegen
open Parking.xcodeproj
```

Pick your team under **Signing & Capabilities** (or set `DEVELOPMENT_TEAM` in
`project.yml`), then run it on your iPhone. On first launch it opens Settings
for the Pass10x login.

## Testing the automation

`tests/run.mjs` runs the same `pass10x.js` against the live site in Chromium,
with the same step order as the app, so changes can be checked without a
phone:

```sh
cd ios/Parking/tests
npm install && npx playwright install chromium
export PASS10X_SUITE=... PASS10X_PASSWORD=...
node run.mjs read                       # active pass and saved guests
node run.mjs activate 769PXT --dry-run  # fill the pass form, do not submit
node run.mjs add ABC123 Pat --dry-run   # fill Setup a Visitor Pass, do not save
node run.mjs remove ABC123 --dry-run    # find the plate's trash icon, do not press it
node run.mjs cancel 769PXT --dry-run    # find the pass's delete button, do not press it
```

Without `--dry-run`, `activate` cancels the active pass and creates one,
`add` saves a plate on the real account, `remove` deletes one, and `cancel`
ends that plate's active pass.
