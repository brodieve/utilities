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
