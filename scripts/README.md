# scripts

## plex-synology-update.sh

Downloads the latest Plex Media Server package for **Synology DSM 7.2.2+** and
installs it with `synopkg`.

Plex publishes its release manifest at `https://plex.tv/api/downloads/5.json`.
DSM 7.2.2 and newer have their own entry there (`Synology (DSM 7.2.2+)`, distro
id `synology-dsm72`), separate from the older DSM 7 packages. The script reads
that entry, picks the build matching the NAS architecture, verifies the
published SHA-1, then stops, installs and restarts the package.

### Usage

Copy it to the NAS and run it as root:

```sh
scp scripts/plex-synology-update.sh admin@nas:/volume1/homes/admin/
ssh admin@nas
sudo -i
/volume1/homes/admin/plex-synology-update.sh
```

```
  -a, --arch ARCH     x86_64, aarch64 or armv7neon (auto-detected from uname -m)
  -t, --token TOKEN   Plex token; defaults to $PLEX_TOKEN
  -c, --channel CH    public (default) or plexpass for early releases
  -d, --dest DIR      download directory (default: first writable of
                      /volume1/@tmp, /var/services/tmp, /tmp)
  -n, --dry-run       download and verify only, do not install
  -f, --force         install even if the installed version already matches
  -k, --keep          keep the downloaded .spk
      --distro ID     override the manifest distro id
  -h, --help          show help
```

It exits 0 without downloading when the installed version already matches, so
it is safe to run from a scheduled task in DSM's Task Scheduler.

### Notes

- Needs root, since `synopkg` does.
- Only depends on `sh`, `curl` or `wget`, `sed`/`grep`/`awk` and `sha1sum` —
  DSM ships neither `jq` nor `python`, so the manifest is parsed with `grep`.
- `synopkg version` reports the version from the package's own `INFO` file,
  whose build suffix differs from the manifest's (`1.43.3.10896-720010896` vs
  `1.43.3.10896-cb3ebc72d`), so only the numeric part is compared.
- `--channel plexpass` needs a Plex Pass account and its token
  ([how to find it](https://support.plex.tv/articles/204059436)).

## nosleep.sh

Keeps a Mac awake for a while in the background, or for as long as a command
runs, with a time limit either way. It turns system sleep off outright with
`pmset disablesleep 1`, so closing the lid does not sleep the Mac either, on
battery and with no external display. macOS-only.

`pmset` needs root, so every session runs `sudo` once. A standard user is
given admin rights by [Privileges](https://github.com/SAP/macOS-enterprise-privileges)
first, with the reason "Run pmset to keep the Mac awake with lid closed",
and they are handed back as soon as `sudo` is done. Expect an authentication
prompt for each of the two.

### Install

Symlink it onto your PATH as `nosleep`, so edits here take effect at once:

```sh
ln -s "$PWD/scripts/nosleep.sh" ~/.local/bin/nosleep
```

### Usage

```
nosleep                       # 60m, in the background
nosleep -t 2h                 # 2h, in the background
nosleep -c make build         # while make runs, for at most 60m
nosleep -t 3h -c make build   # while make runs, for at most 3h
nosleep -t 3h make build      # -c is optional
nosleep -c 'make && say done' # one quoted argument runs in $SHELL
```

```
  -t, --time DURATION   the longest to hold off sleep (default 60m): 90s,
                        45m, 2h, 1h30m, 1d; a bare number is minutes
  -c, --command CMD...  run CMD and hold off sleep while it runs; everything
                        after -c is the command, so it goes last
  -h, --help            show help
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `NOSLEEP_FLAGS` | `-i` | `caffeinate` assertion flags for the session. `-di` keeps the display on as well; otherwise it sleeps and locks as usual. |

### How it works

- **The lease.** A `caffeinate` owned by you stands for the session. It ends
  at the time limit, when the command exits (`-w`), or when you `kill` the pid
  the background forms print, which needs no admin rights.
- **The root guard.** `sudo` starts a root process that turns sleep off,
  waits for the lease to end, and turns sleep back on. It never needs `sudo`
  again, so it outlives Privileges' 5-minute expiry and the revocation on
  screen lock.
- **Overlapping sessions** are counted under a lock in `/var/db/nosleep`.
  Sleep comes back only when the last one ends, and to whatever
  `disablesleep` was before the first, so a `pmset disablesleep 1` you set
  yourself is left alone.

### Notes

- While a session is live, nothing sleeps the Mac: not the lid, not idle
  time, not the Apple menu. A closed laptop in a bag stays awake, and warm,
  until the time limit.
- With a command, reaching the time limit only lets the Mac sleep again. The
  command keeps running, keeps its pid and exit status, and stays in the
  foreground. ^C and ^Z the command survives do not end the session early.
- Closing the terminal does not end a background session.
- The guard turns sleep back on if it is sent TERM, as at logout. Only
  SIGKILL or a crash or power loss mid-session can skip that. `disablesleep`
  persists across reboots, and so does the bookkeeping, so the next session
  restores the original setting when it ends. To fix it by hand instead:
  `sudo pmset -a disablesleep 0`.
- `pmset -g | grep SleepDisabled` shows whether sleep is off;
  `pmset -g assertions` shows what else is keeping the Mac awake.
- The guard is this script run as root, so anything that can write to it can
  run as root the next time you start a session. Keep it somewhere only you
  can write.

## root.sh

Asks [Privileges](https://github.com/SAP/macOS-enterprise-privileges) for
admin rights, with a one-sentence Buddhist, philosophical reason of 20 words
or less written by Claude Haiku. Each reason draws on a teaching picked at
random (impermanence, non-self, the Middle Way, …); give it a purpose and the
reason is written around that too. macOS-only.

### Install

Symlink it onto your PATH as `root`, so edits here take effect at once:

```sh
ln -s "$PWD/scripts/root.sh" ~/.local/bin/root
```

### Usage

```
root                    # admin rights, with a generated reason
root updating Homebrew  # the reason is written around this
root -n                 # print a reason without asking for rights
root -r                 # hand admin rights back
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `ROOT_MODEL` | `claude-haiku-5-5` | The model that writes the reason. |

### Notes

- The `claude -p` call carries no tools, MCP servers, skills, settings,
  `CLAUDE.md` or saved session, and runs at low effort, so Haiku answers
  without thinking: about 650 input tokens and 1–3 seconds. `--bare` would
  trim more, but it only takes `ANTHROPIC_API_KEY`, not a claude.ai login.
- If `claude` is missing, fails, or twice gives something that is not 3–20
  words, a fixed reason is used instead.
- Privileges sends the reason, with your email and serial number, to remote
  logging, so it is read by more than you.

## obsidian-sync-guard.sh

Keeps Obsidian Sync turned on and connected in the vaults it guards on a Mac.
If the Sync core plugin is turned off in one, it is turned back on; if Sync
loses its remote vault, it is reconnected from a copy of its config saved in
the Keychain. macOS-only.

Turning the plugin back on is not enough by itself. When a vault opens with
Sync off, Obsidian deletes the vault's IndexedDB database `<vault id>-sync`
30 seconds later. That database is all of Sync's local config: the remote
vault, its encryption key, the device name and the selective sync settings.
Once it is gone, Sync has to be set up again by hand.

### Install

Turn on Obsidian's command line interface first, in Settings → General →
Advanced. The guard needs it to save the config, to restore it, and to turn
Sync back on in an Obsidian that is already running.

Symlink the script onto your PATH as `obsidian-sync-guard`, so edits here take
effect at once. Then install each vault to guard, with the vault open and
Sync connected:

```sh
ln -s "$PWD/scripts/obsidian-sync-guard.sh" ~/.local/bin/obsidian-sync-guard
obsidian-sync-guard -v Notes install
obsidian-sync-guard -v Work install
```

`install` saves the vault's config and starts a LaunchAgent for it,
`com.brodieve.obsidian-sync-guard.<hash of the vault's path>`, leaving any
other vault's alone. Each checks its vault at login, whenever the vault's
`core-plugins.json` or Obsidian's vault list changes, and every 5 minutes.
With only one vault in Obsidian, `-v` can be left out.

### Usage

```
obsidian-sync-guard -v Notes install   # save Notes' Sync config and guard it
obsidian-sync-guard status             # how Sync and the guard stand, in each
obsidian-sync-guard save               # save each one's Sync config now
obsidian-sync-guard check              # check each once, as the agents do
obsidian-sync-guard -v Notes status    # just Notes, guarded or not
obsidian-sync-guard -v Notes uninstall # stop guarding Notes
obsidian-sync-guard uninstall          # stop guarding every vault
obsidian-sync-guard -v Notes -c .config install # name the vault's config folder
```

```
  -v, --vault VAULT   the vault, by path or folder name; without it, install
                      takes Obsidian's only vault, and the other commands
                      every guarded vault, or Obsidian's only one if none is
  -c, --config-folder FOLDER
                      the vault's config folder, such as .obsidian; found on
                      its own: Obsidian is asked, or else it is the one
                      folder in the vault that looks like one
  -h, --help          show help
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `OBSIDIAN_CLI` | found on its own | Obsidian's command line tool, if it is not at `/usr/local/bin/obsidian` or inside `Obsidian.app`. |

### How it works

- **The switch.** `core-plugins.json`, in the vault's config folder, records
  which core plugins are on. The vault's agent watches it and sets `"sync"`
  back to `true` as soon as anything turns it off, whether Obsidian is
  running or not, so the vault next opens with Sync on and the database is
  kept. The folder is `.obsidian` unless Obsidian on this Mac is set to use
  another, in Settings → Files and links → Override config folder. `install`
  asks Obsidian which, and the agent watches that one. The switch is all of
  Sync that is in the folder; Sync's config is in the database.
- **The running app.** Through `obsidian eval`, the guard runs a short script
  inside the vault's window. It turns the Sync plugin back on if it is off.
  If the database has no remote vault, it writes the saved config back and
  reloads the plugin. Opening a vault also changes Obsidian's vault list,
  which triggers a check. Obsidian holds the request until the vault has
  loaded, so the check runs before the 30-second clean-up.
- **The saved config** is the database's record without its per-file sync
  state: the remote vault's id and name, its encryption key and salt, the
  server, the device name and the selective sync settings. It is kept in
  the login Keychain under service `obsidian-sync-guard`, with the vault's
  path as the account. `security` writes and reads it from inside Obsidian,
  so the key never appears on a command line. Each check that finds Sync
  connected refreshes the copy, so it follows changes to Sync's settings.

### Notes

- The first sync after a restore runs as it does after connecting by hand:
  Sync compares the whole vault with the remote one from scratch.
- To turn Sync off or disconnect it on purpose, run `-v VAULT uninstall`
  first, or the guard undoes it.
- Without the command line interface, only `core-plugins.json` is guarded.
  If the vault still opens with Sync off, the connection is lost and has to
  be set up again by hand.
- If the vault's folder is missing when Obsidian starts, Obsidian drops the
  vault from its list and deletes its local data, Sync's database with it.
  This happens with an unmounted drive or a cloud folder not yet downloaded.
  Once the vault is opened again it has a new id. The guard finds it by
  path and restores the config into it. An overridden config folder is
  forgotten too, so Obsidian opens the vault with `.obsidian`; see below.
  Until then, `status` and `check` report the vault missing, and
  `uninstall` takes it by the path it had, not by name.
- If Obsidian is using another config folder than the one the guard was
  installed with, the guard leaves Sync alone and logs why: turned on
  there, Sync would sync that folder's settings instead, from scratch. Set
  the folder again in Settings → Files and links → Override config folder,
  and the guard carries on. Changed it on purpose? Run `install` again.
- macOS privacy protection covers Documents, Desktop and iCloud Drive. For
  a vault in one of those, macOS may ask whether `sh` or `osascript` can
  open the folder, or refuse without asking. Unless it is allowed, the
  agent cannot fix `core-plugins.json`. Restoring through Obsidian still
  works.
- Each vault is guarded on its own, by its own agent, so one vault opening
  or failing does not hold up another. An agent installed by v1.0,
  `com.brodieve.obsidian-sync-guard` with no hash, still works and shows in
  `status`; installing its vault again moves it to the new label.
- It relies on Obsidian internals as of 1.14.5: `app.internalPlugins` and
  the layout of Sync's IndexedDB record. If an update changes them, the
  guard logs errors rather than restoring.
- Only what it does gets logged, to `~/Library/Logs/obsidian-sync-guard.log`,
  one log for every vault, each line naming its vault.
  `uninstall` leaves the saved config in the Keychain.
  `security delete-generic-password -s obsidian-sync-guard -a VAULT_PATH`
  deletes it.
