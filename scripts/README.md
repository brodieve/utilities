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
