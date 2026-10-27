#!/bin/sh
#
# obsidian-sync-guard.sh
#
# Keep Obsidian Sync turned on and connected in the vaults it guards on this
# Mac. If the Sync core plugin is turned off it is turned back on, and if its
# link to the remote vault is lost it is restored from a copy saved in the
# Keychain. Install it on PATH as `obsidian-sync-guard`.
#
#   obsidian-sync-guard -v Notes install   # save a vault's Sync config and guard it
#   obsidian-sync-guard status             # how Sync and the guard stand in each
#   obsidian-sync-guard save               # save each one's Sync config again now
#   obsidian-sync-guard uninstall          # stop guarding them all
#
# Why the connection as well as the switch: when a vault opens with the Sync
# plugin off, Obsidian deletes the vault's IndexedDB database
# "<vault id>-sync" 30 seconds later. That database is all of Sync's local
# config: the remote vault, its encryption key, the device name and the
# selective sync settings, so Sync then has to be set up again by hand.
#
# How the pieces fit:
#
#   - core-plugins.json, in the vault's config folder, records which core
#     plugins are on. Each guarded vault has a LaunchAgent of its own, which
#     watches it and turns "sync" back on as soon as anything turns it off,
#     so the vault next opens with Sync on.
#     The folder is .obsidian unless Obsidian on this Mac is set to use
#     another (Settings > Files and links > Override config folder). Only
#     the switch is in it: Sync's config is not.
#   - In a running Obsidian, it works through Obsidian's own command line
#     interface (`obsidian eval`): it turns the plugin back on, and if the
#     database has lost the remote vault, writes the saved config into it and
#     reloads the plugin. Run as the vault opens, it gets in ahead of the
#     30-second clean-up.
#   - The saved config holds the vault's encryption key, so it is kept in the
#     login Keychain, and written and read from inside Obsidian so the key
#     never passes through a command line. Each check that finds Sync
#     connected refreshes it, so it follows changes made in Sync's settings.
#
# Written against Obsidian 1.14.5, whose internals it relies on. POSIX sh,
# macOS only.
#
# v1.0 - brodieve - initial
# v1.1 - brodieve - guard several vaults
#

set -eu

# Each vault's LaunchAgent is labelled LABEL.<hash of the vault's path>.
LABEL=com.brodieve.obsidian-sync-guard
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
# Every vault's agent logs here.
LOG="$HOME/Library/Logs/obsidian-sync-guard.log"
KEYCHAIN_SERVICE=obsidian-sync-guard
OBSIDIAN_APP=/Applications/Obsidian.app
OBSIDIAN_CONFIG="$HOME/Library/Application Support/obsidian/obsidian.json"
# The agent checks this often, on top of whenever core-plugins.json or
# Obsidian's vault list changes.
INTERVAL=300
# Obsidian holds a CLI request until the vault has finished loading.
CLI_TIMEOUT=60
CLI_OFF="Obsidian's command line interface is off; turn it on in Settings > General > Advanced"

usage() {
    cat <<'EOF'
Usage: obsidian-sync-guard [-v VAULT] [-c FOLDER] COMMAND

Keep Obsidian Sync turned on and connected in the vaults it guards. If the
Sync core plugin is turned off it is turned back on, and if its link to the
remote vault is lost it is restored from a copy saved in the Keychain.

Commands:
  install     Save the vault's Sync config and guard it from now on, at
              login too, with a LaunchAgent. Install each vault to guard;
              the others stay guarded.
  uninstall   Stop guarding. The saved config stays in the Keychain.
  status      Show how Sync and the guard stand.
  save        Save the Sync config now. The guard also refreshes it
              whenever it finds Sync connected.
  check       Check once, restoring whatever is missing. The LaunchAgent
              runs this.

Options:
  -v, --vault VAULT   The vault, by path or folder name. Without it, install
                      takes Obsidian's only vault, and the other commands
                      every guarded vault, or Obsidian's only one if none is.
  -c, --config-folder FOLDER
                      The vault's config folder, such as .obsidian. Found on
                      its own: Obsidian is asked, or else it is the one
                      folder in the vault that looks like one.
  -h, --help          Show this help.

Saving the config, restoring it, and turning Sync back on in an Obsidian
that is already running all go through Obsidian's command line interface:
turn it on in Settings > General > Advanced. Without it, only
core-plugins.json is guarded, which takes effect when the vault next opens.

If Obsidian is using another config folder than the one the guard was set
up with, the guard leaves Sync alone there, as Sync would sync the wrong
folder's settings. Changed it on purpose? Install that vault again.

Turning Sync off or disconnecting it on purpose? Uninstall that vault
first, or the guard will undo it.

Environment:
  OBSIDIAN_CLI   Obsidian's command line tool (default: found on its own)
EOF
}

# TAG names the vault, where there may be several to tell apart: in the log,
# which every vault's agent writes to, and when a command acts on them all.
note() {
    if [ -t 2 ]; then
        printf 'obsidian-sync-guard: %s%s\n' "$TAG" "$*" >&2
    else
        printf '%s obsidian-sync-guard: %s%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TAG" "$*" >&2
    fi
}
die()         { note "$*"; exit 1; }
usage_error() { note "$*"; printf 'Try obsidian-sync-guard --help.\n' >&2; exit 2; }
have()        { command -v "$1" >/dev/null 2>&1; }

notify() {
    osascript -e 'on run argv' \
              -e 'display notification (item 1 of argv) with title "Obsidian Sync"' \
              -e 'end run' "$1" >/dev/null 2>&1 || true
}

xml_escape() { printf '%s\n' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# ----------------------------------------------------------------- JSON
#
# Read and written with JavaScript for Automation: osascript is on every Mac,
# jq and python are not.

# Look up the vault Obsidian knows by path or folder name $1, or its only
# vault if $1 is empty. Print, tab-separated, "ok ID PATH OPEN CLI", where
# OPEN is 1 if the vault is open (or will reopen when Obsidian starts) and
# CLI is 1 if Obsidian's command line interface is on; or "err MESSAGE".
vault_info() {
    osascript -l JavaScript - "$OBSIDIAN_CONFIG" "$1" <<'EOF'
ObjC.import('Foundation');
function real(path) {
    return $(path).stringByStandardizingPath.stringByResolvingSymlinksInPath.js;
}
function run(argv) {
    const config = argv[0], query = argv[1] || '';
    let data;
    try {
        data = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(
            config, $.NSUTF8StringEncoding, null).js);
    } catch (e) {
        return 'err\tcould not read ' + config;
    }
    const vaults = Object.entries(data.vaults || {});
    let found;
    if (!query) {
        if (vaults.length === 0) return 'err\tObsidian has no vaults';
        if (vaults.length > 1)
            return 'err\tObsidian has ' + vaults.length + ' vaults; pick one with -v: ' +
                vaults.map(v => v[1].path).join(', ');
        found = vaults;
    } else if (query.startsWith('/')) {
        found = vaults.filter(v => real(v[1].path) === real(query));
    } else {
        /* By folder name, ignoring case, as Obsidian's own CLI does. */
        found = vaults.filter(v =>
            v[1].path.split('/').pop().toUpperCase() === query.toUpperCase());
    }
    if (found.length === 0)
        return 'err\tObsidian has no vault ' + (query.startsWith('/') ? 'at ' : 'named ') + query;
    if (found.length > 1)
        return 'err\tObsidian has several vaults named ' + query + '; give its path instead';
    const id = found[0][0], vault = found[0][1];
    return ['ok', id, vault.path, vault.open ? 1 : 0, data.cli ? 1 : 0].join('\t');
}
EOF
}

# Print whether core-plugins.json $1 has the Sync plugin "on" or "off", or
# that it is "missing" or "unreadable". With $2 set to "fix", turn Sync back
# on if it is off and print "fixed", or "unwritable".
core_plugins() {
    osascript -l JavaScript - "$1" "${2:-}" <<'EOF'
ObjC.import('Foundation');
function run(argv) {
    const path = argv[0], fix = argv[1] === 'fix';
    /* With no file, Obsidian turns on its default core plugins, Sync among them. */
    if (!$.NSFileManager.defaultManager.fileExistsAtPath(path)) return 'missing';
    const text = $.NSString.stringWithContentsOfFileEncodingError(
        path, $.NSUTF8StringEncoding, null);
    if (text.isNil()) return 'unreadable';
    let config;
    try { config = JSON.parse(text.js); } catch (e) { return 'unreadable'; }
    /* {"plugin": true|false, ...}, where a plugin left out takes its default,
       which for Sync is on; or, in older vaults, a list of the plugins on. */
    const list = Array.isArray(config);
    if (!list && (config === null || typeof config !== 'object')) return 'unreadable';
    if (list ? config.includes('sync') : !('sync' in config) || config.sync) return 'on';
    if (!fix) return 'off';
    if (list) config.push('sync'); else config.sync = true;
    const written = $(JSON.stringify(config, null, 2)).writeToFileAtomicallyEncodingError(
        path, true, $.NSUTF8StringEncoding, null);
    return written ? 'fixed' : 'unwritable';
}
EOF
}

# ------------------------------------------------------------- in Obsidian

# Print the JavaScript that runs inside Obsidian, in the vault's window, in
# mode $1:
#
#   status   look only
#   save     save the config to the Keychain
#   check    turn the plugin on if it is off; if Sync has lost its remote
#            vault, restore the saved config; then save the config. Do
#            nothing if Obsidian is not using config folder CONFIG_DIR.
#
# It answers with one line: "ok", "off", "disconnected" or "elsewhere"; what
# it did, of "enabled", "reconnected", "saved" and "updated"; with "ok", the
# remote vault's name as name=BASE64; and the config folder Obsidian is
# using as dir=BASE64. A failure is "error: MESSAGE".
#
# Obsidian keeps Sync's config as one record, key "data" in object store
# "data", in the IndexedDB database "<vault id>-sync". What is saved is the
# record less its per-file sync state. A restore starts that state afresh,
# as Obsidian does when it connects a vault, so the first sync after it
# compares the vault with the remote one from scratch.
sync_js() {
    b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
    printf 'const MODE = "%s", SERVICE = "%s", ACCOUNT_B64 = "%s", CONFIG_DIR_B64 = "%s";\n' \
        "$1" "$KEYCHAIN_SERVICE" "$(b64 "$VAULT_PATH")" "$(b64 "$CONFIG_DIR")"
    cat <<'EOF'
(async () => {
    const plugin = app.internalPlugins.getPluginById("sync");
    if (!plugin) return "error: this Obsidian has no Sync plugin";
    const STATE = ["appId", "version", "initial", "local", "remote", "pending"];
    const done = [];

    const encode = text => btoa(String.fromCharCode(...new TextEncoder().encode(text)));
    const decode = b64 => new TextDecoder().decode(Uint8Array.from(atob(b64), c => c.charCodeAt(0)));
    const answer = (...words) => [...words, "dir=" + encode(app.vault.configDir)].join(" ");
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const until = async test => {
        for (let i = 0; i < 100; i++) {
            if (test()) return true;
            await sleep(100);
        }
        return false;
    };

    const idb = (mode, op) => new Promise((resolve, reject) => {
        const open = indexedDB.open(app.appId + "-sync", 1);
        open.onupgradeneeded = () => open.result.createObjectStore("data");
        open.onerror = () => reject(open.error);
        open.onsuccess = () => {
            const db = open.result;
            try {
                const tx = db.transaction("data", mode);
                const request = op(tx.objectStore("data"));
                tx.oncomplete = () => { db.close(); resolve(request.result); };
                tx.onerror = tx.onabort = () => { db.close(); reject(tx.error); };
            } catch (e) {
                db.close();
                reject(e);
            }
        };
    });

    const security = (args, input) => new Promise((resolve, reject) => {
        const child = require("child_process").execFile("/usr/bin/security", args,
            (error, stdout) => error ? reject(error) : resolve(stdout.trim()));
        child.stdin.end(input || "");
    });
    const keychain = ["-s", SERVICE, "-a", decode(ACCOUNT_B64)];
    const loadSaved = async () => {
        try {
            return await security(["find-generic-password", ...keychain, "-w"]);
        } catch (e) {
            if (e.code === 44) return "";
            throw new Error("could not read the saved config from the Keychain");
        }
    };
    /* Through security's own prompt on stdin, not its arguments, which other
       processes can read. It reads lines of up to 4096 bytes. */
    const save = async value => {
        const quote = s => '"' + s.replace(/[\\"]/g, "\\$&") + '"';
        const line = "add-generic-password -U " +
            keychain.map((arg, i) => i % 2 ? quote(arg) : arg).join(" ") +
            " -w " + quote(value) + "\n";
        if (new TextEncoder().encode(line).length > 4094)
            throw new Error("the config is too big for the Keychain helper, at " + value.length +
                " bytes; excluding fewer folders from Sync makes it smaller");
        await security(["-i"], line).catch(() => {});
        if (await loadSaved() !== value) throw new Error("could not save the config to the Keychain");
    };

    /* The folder was changed, or forgotten: Obsidian keeps the choice with
       this Mac's data for the vault, which goes when the vault does. Sync
       would now sync another folder's settings, from scratch. */
    if (MODE === "check" && CONFIG_DIR_B64 && app.vault.configDir !== decode(CONFIG_DIR_B64))
        return answer("elsewhere");

    if (!plugin.enabled) {
        if (MODE !== "check") return answer("off");
        await plugin.enable(false);
        done.push("enabled");
    }
    /* Sync loads its record once it is on and the workspace is ready. */
    await until(() => plugin.instance.dataLoaded);
    let record = await idb("readonly", store => store.get("data"));
    const saved = MODE === "status" ? "" : await loadSaved();

    if (MODE === "check" && saved && !(record && record.vaultId)) {
        const config = JSON.parse(decode(saved));
        record = Object.assign({}, config, {
            appId: app.appId, version: 0, initial: true, local: {}, remote: {}, pending: []
        });
        /* Off while the record is written so Sync cannot save over it, then
           on again to load it. */
        plugin.disable(false);
        await idb("readwrite", store => store.put(record, "data"));
        await plugin.enable(false);
        if (!await until(() => plugin.instance.getRemoteVaultId() === config.vaultId))
            return "error: Sync did not take up the restored config";
        done.push("reconnected");
    }
    if (!(record && record.vaultId)) return answer("disconnected", ...done);

    if (MODE !== "status") {
        const config = Object.assign({}, record);
        for (const key of STATE) delete config[key];
        const value = encode(JSON.stringify(config));
        if (value !== saved) {
            await save(value);
            done.push(saved ? "updated" : "saved");
        }
    }
    return answer("ok", ...done, "name=" + encode(record.vaultName || ""));
})().catch(e => "error: " + (e.message || e))
EOF
}

# Print the path of Obsidian's command line tool.
find_cli() {
    for cli in "${OBSIDIAN_CLI:-}" /usr/local/bin/obsidian \
               "$(command -v obsidian 2>/dev/null || true)" \
               "$OBSIDIAN_APP/Contents/MacOS/obsidian-cli" \
               "$OBSIDIAN_APP/Contents/MacOS/Obsidian"; do
        if [ -n "$cli" ] && [ -x "$cli" ]; then
            printf '%s\n' "$cli"
            return 0
        fi
    done
    return 1
}

# Succeed, setting CLI, if the vault is open in a running Obsidian that takes
# CLI requests. A request otherwise would start Obsidian or open the vault.
obsidian_reachable() {
    [ "$VAULT_OPEN" = 1 ] && [ "$CLI_ON" = 1 ] &&
        pgrep -x Obsidian >/dev/null && CLI=$(find_cli)
}

# Run Obsidian's command line tool with arguments "$@", printing what it
# prints, and stop it after CLI_TIMEOUT seconds. Its input is held open and
# never written until it is done: the tool hands its input on to Obsidian,
# and input that ends at once, as /dev/null does under launchd, can close the
# connection before Obsidian has answered.
run_cli() {
    dir=$(mktemp -d "${TMPDIR:-/tmp}/obsidian-sync-guard.XXXXXX")
    mkfifo "$dir/in"
    "$CLI" "$@" <"$dir/in" 2>&1 &
    pid=$!
    # Its output goes nowhere, so a $(...) around this need not wait on it.
    (sleep "$CLI_TIMEOUT"; kill "$pid" 2>/dev/null) >/dev/null 2>&1 &
    watchdog=$!
    exec 3>"$dir/in"
    rc=0
    wait "$pid" || rc=$?
    exec 3>&-
    kill "$watchdog" 2>/dev/null || true
    rm -rf "$dir"
    return "$rc"
}

# Run sync_js in mode $1 in the vault and print its answer. Fail, saying why,
# if Obsidian does not answer or the script fails.
ask_obsidian() {
    out=$(run_cli "vault=$VAULT_ID" eval "code=$(sync_js "$1")") || {
        rc=$?
        [ "$rc" -ne 143 ] || { note "Obsidian did not answer within ${CLI_TIMEOUT}s"; return 1; }
        note "obsidian eval failed: $(printf '%s\n' "$out" | tail -n 1)"
        return 1
    }
    reply=$(printf '%s\n' "$out" | sed -n 's/^=> //p' | tail -n 1)
    case "$reply" in
        ok*|off*|disconnected*|elsewhere*) printf '%s\n' "$reply" ;;
        error:*) note "${reply#error: }"; return 1 ;;
        *)       note "unexpected answer from Obsidian: $(printf '%s\n' "$out" | tail -n 1)"
                 return 1 ;;
    esac
}

# Print field $1, sent as $1=BASE64, of answer $2.
reply_field() {
    printf '%s\n' "$2" | sed -n "s/.* $1=\([^ ]*\).*/\1/p" | base64 --decode 2>/dev/null || true
}

# Succeed if $1 is a name Obsidian takes for a config folder.
valid_config_dir() {
    case "$1" in
        .|..|*/*|*\\*|*:*) return 1 ;;
        .*)                return 0 ;;
        *)                 return 1 ;;
    esac
}

# Print the name of the vault's config folder: as Obsidian says, if it has
# the vault open and answers, or else the one folder in the vault that holds
# core-plugins.json or app.json, or else .obsidian. Fail if there are
# several, as there can be: the name is chosen per device.
find_config_dir() {
    if obsidian_reachable && reply=$(ask_obsidian status) &&
       dir=$(reply_field dir "$reply") && [ -n "$dir" ]; then
        printf '%s\n' "$dir"
        return 0
    fi
    count=0 found='' names=''
    for dir in "$VAULT_PATH"/.*/; do
        dir=${dir%/}
        name=${dir##*/}
        case "$name" in .|..) continue ;; esac
        [ -f "$dir/core-plugins.json" ] || [ -f "$dir/app.json" ] || continue
        count=$((count + 1))
        found=$name
        names="${names:+$names, }$name"
    done
    case "$count" in
        0) printf '.obsidian\n' ;;
        1) printf '%s\n' "$found" ;;
        *) note "$VAULT_NAME has $count config folders, $names; pick one with --config-folder"
           return 1 ;;
    esac
}

# Save the config through Obsidian, saying how it went. Fail if it could not.
save_config() {
    if ! pgrep -x Obsidian >/dev/null || [ "$VAULT_OPEN" != 1 ]; then
        note "open $VAULT_NAME in Obsidian to save its Sync config"
        return 1
    fi
    [ "$CLI_ON" = 1 ] || { note "$CLI_OFF"; return 1; }
    CLI=$(find_cli) || { note "Obsidian's command line tool not found; set OBSIDIAN_CLI"; return 1; }
    reply=$(ask_obsidian save) || return 1
    case "$reply" in
        off*)          note "Sync is off in $VAULT_NAME; turn it on and connect it first"; return 1 ;;
        disconnected*) note "Sync is not connected to a remote vault in $VAULT_NAME; connect it first"; return 1 ;;
    esac
    case " $reply " in
        *' saved '*|*' updated '*)
            note "saved the Sync config for remote vault \"$(reply_field name "$reply")\" to the Keychain" ;;
        *)  note "the saved Sync config for remote vault \"$(reply_field name "$reply")\" is up to date" ;;
    esac
    dir=$(reply_field dir "$reply")
    [ "$dir" = "$CONFIG_DIR" ] || note "Obsidian is using $dir as the config folder, not $CONFIG_DIR"
}

# -------------------------------------------------------- vaults and guards

# Look up the vault Obsidian knows by path or folder name $1, or its only
# vault if $1 is empty, setting VAULT_ID, VAULT_PATH, VAULT_NAME, VAULT_OPEN
# and CLI_ON. Fail, saying why, if there is no such vault.
find_vault() {
    query=$1
    if [ -n "$query" ] && [ -d "$query" ]; then
        query=$(CDPATH='' cd -- "$query" && pwd)
    fi
    info=$(vault_info "$query") || { note "could not read $OBSIDIAN_CONFIG"; return 1; }
    IFS=$tab read -r result VAULT_ID VAULT_PATH VAULT_OPEN CLI_ON <<EOF
$info
EOF
    [ "$result" = ok ] || { note "$VAULT_ID"; return 1; }
    VAULT_NAME=${VAULT_PATH##*/}
    if [ ! -t 2 ] || [ "$MANY" = 1 ]; then TAG="$VAULT_NAME: "; fi
}

# Print the label of the vault's LaunchAgent.
vault_label() {
    printf '%s.%s\n' "$LABEL" "$(printf '%s' "$VAULT_PATH" | shasum | cut -c 1-8)"
}

# Print, tab-separated, the plist, vault path and config folder of each
# vault's LaunchAgent, read from the ProgramArguments plist() writes, in
# order of vault path. v1.0's single agent, labelled LABEL alone, is one of
# them, until its vault is installed again.
guards() {
    for file in "$AGENTS/$LABEL.plist" "$AGENTS/$LABEL".*.plist; do
        [ -f "$file" ] || continue
        vault=$(plutil -extract ProgramArguments.3 raw -o - "$file" 2>/dev/null) || continue
        dir=$(plutil -extract ProgramArguments.5 raw -o - "$file" 2>/dev/null) || continue
        printf '%s\t%s\t%s\n' "$file" "$vault" "$dir"
    done | sort -t "$tab" -k 2,2
}

# Set GUARD to the plist of the vault's LaunchAgent and GUARD_DIR to the
# config folder it guards. Fail if the vault is not guarded.
find_guard() {
    while IFS=$tab read -r file vault dir; do
        [ -n "$file" ] && [ "$vault" = "$VAULT_PATH" ] || continue
        GUARD=$file GUARD_DIR=$dir
        return 0
    done <<EOF
$(guards)
EOF
    return 1
}

# Stop LaunchAgent $1 if it is loaded. bootout returns before the job is
# gone, and bootstrap fails until it is, so wait for that.
unload() {
    launchctl bootout "$DOMAIN/$1" 2>/dev/null || true
    tries=0
    while launchctl print "$DOMAIN/$1" >/dev/null 2>&1 && [ "$tries" -lt 50 ]; do
        tries=$((tries + 1))
        sleep 0.1
    done
}

# Stop and delete the LaunchAgents guarding vault path $1, or every vault if
# $1 is empty, printing the path of each vault they guarded.
remove_guards() {
    while IFS=$tab read -r file vault dir; do
        [ -n "$file" ] || continue
        [ -z "$1" ] || [ "$vault" = "$1" ] || continue
        unload "$(basename "$file" .plist)"
        rm -f "$file"
        printf '%s\n' "$vault"
    done <<EOF
$(guards)
EOF
}

# --------------------------------------------------------------- commands

cmd_check() {
    rc=0
    file="$VAULT_PATH/$CONFIG_DIR/core-plugins.json"
    case "$(core_plugins "$file" fix)" in
        on|missing) ;;
        fixed)      note "Sync was off in $file; turned it back on" ;;
        unreadable) note "could not read $file as JSON; left it alone"; rc=1 ;;
        *)          note "could not turn Sync back on in $file"; rc=1 ;;
    esac

    obsidian_reachable || return "$rc"
    reply=$(ask_obsidian check) || return 1
    case "$reply" in
        elsewhere*)
            note "Obsidian is using $(reply_field dir "$reply") as $VAULT_NAME's config folder, not $CONFIG_DIR, so Sync was left alone"
            note "to guard that folder, run obsidian-sync-guard -v \"$VAULT_PATH\" install; to go back to $CONFIG_DIR, set it in Settings > Files and links > Override config folder"
            return 1 ;;
    esac
    set -f
    # shellcheck disable=SC2086 # split into words on purpose
    set -- $reply
    set +f
    for word in "$@"; do
        case "$word" in
            enabled)     note "Sync was off in Obsidian; turned it back on"
                         notify "Sync was off in $VAULT_NAME and has been turned back on." ;;
            reconnected) note "Sync had lost its remote vault; restored the saved config"
                         notify "Sync in $VAULT_NAME had lost its remote vault and has been reconnected." ;;
            saved)       note "saved the Sync config to the Keychain" ;;
            updated)     note "updated the saved Sync config" ;;
        esac
    done
    # With a saved config, it would have been restored. Said only when run by
    # hand, as the agent would say it every few minutes.
    if [ "$1" = disconnected ] && [ -t 2 ]; then
        note "Sync is not connected in $VAULT_NAME, and there is no saved config to restore"
    fi
    return "$rc"
}

cmd_save() {
    save_config || exit 1
}

cmd_status() {
    row() { printf '%-13s%s\n' "$1" "$2"; }

    row vault "$VAULT_PATH"
    file="$CONFIG_DIR/core-plugins.json"
    case "$(core_plugins "$VAULT_PATH/$file")" in
        on)      row 'sync plugin' "on in $file" ;;
        off)     row 'sync plugin' "off in $file" ;;
        missing) row 'sync plugin' "on by default, with no $file" ;;
        *)       row 'sync plugin' "$file could not be read" ;;
    esac

    if ! pgrep -x Obsidian >/dev/null; then
        row obsidian 'not running'
    elif [ "$VAULT_OPEN" != 1 ]; then
        row obsidian 'running, vault not open'
    elif [ "$CLI_ON" != 1 ]; then
        row obsidian 'running, command line interface off'
    elif ! CLI=$(find_cli); then
        row obsidian 'running, command line tool not found'
    elif reply=$(ask_obsidian status); then
        case "$reply" in
            ok*)  row obsidian "Sync connected to remote vault \"$(reply_field name "$reply")\"" ;;
            off*) row obsidian 'Sync plugin off' ;;
            *)    row obsidian 'Sync not connected' ;;
        esac
        dir=$(reply_field dir "$reply")
        [ "$dir" = "$CONFIG_DIR" ] || row '' "using config folder $dir, not $CONFIG_DIR"
    else
        row obsidian 'running, did not answer'
    fi

    if saved=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$VAULT_PATH" -w 2>/dev/null); then
        name=$(printf '%s' "$saved" | base64 --decode 2>/dev/null |
            sed -n 's/.*"vaultName":"\([^"]*\)".*/\1/p')
        row saved "Sync config for remote vault \"$name\", in the Keychain"
    else
        row saved 'nothing yet'
    fi

    if ! find_guard; then
        row guard 'not installed'
    elif ! launchctl print "$DOMAIN/$(basename "$GUARD" .plist)" >/dev/null 2>&1; then
        row guard "installed but not running: $GUARD"
    elif [ "$GUARD_DIR" = "$CONFIG_DIR" ]; then
        row guard "running, logging to $LOG"
    else
        row guard "running for another config folder; install again to guard $CONFIG_DIR"
    fi
}

# Print the vault's LaunchAgent, labelled $2, running script $1: a check at
# login, whenever core-plugins.json or Obsidian's vault list changes, which
# it does as a vault opens, and every INTERVAL seconds besides. guards()
# reads the vault and config folder back from ProgramArguments, by place.
plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$2</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>$(xml_escape "$1")</string>
        <string>--vault</string>
        <string>$(xml_escape "$VAULT_PATH")</string>
        <string>--config-folder</string>
        <string>$(xml_escape "$CONFIG_DIR")</string>
        <string>check</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>$(xml_escape "$VAULT_PATH/$CONFIG_DIR/core-plugins.json")</string>
        <string>$(xml_escape "$OBSIDIAN_CONFIG")</string>
    </array>
    <key>StartInterval</key>
    <integer>$INTERVAL</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$(xml_escape "$LOG")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$LOG")</string>
</dict>
</plist>
EOF
}

cmd_install() {
    here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    script="$here/$(basename -- "$0")"

    if [ "$CLI_ON" != 1 ]; then
        note "$CLI_OFF; until then, only core-plugins.json is guarded"
    elif ! save_config; then
        note "the guard saves the config the first time it finds Sync connected in an open vault"
    fi

    # Whatever agent guards the vault already, this one or v1.0's, makes way.
    remove_guards "$VAULT_PATH" >/dev/null
    label=$(vault_label)
    agent="$AGENTS/$label.plist"
    mkdir -p "$AGENTS" "$(dirname "$LOG")"
    plist "$script" "$label" >"$agent.tmp"
    mv -f "$agent.tmp" "$agent"
    launchctl bootstrap "$DOMAIN" "$agent" || die "launchctl could not load $agent"

    note "guarding $VAULT_PATH, with config folder $CONFIG_DIR; what it does is logged to $LOG"
}

# Stop guarding vault path VAULT_PATH, or every vault if it is empty.
cmd_uninstall() {
    removed=$(remove_guards "$VAULT_PATH")
    if [ -z "$removed" ]; then
        note "not guarding ${VAULT_PATH:-any vault}"
        return 0
    fi
    printf '%s\n' "$removed" | while IFS= read -r vault; do
        note "stopped guarding $vault"
    done
    note "the saved config is still in the Keychain, and"
    note "security delete-generic-password -s $KEYCHAIN_SERVICE -a VAULT_PATH deletes it"
}

# ---------------------------------------------------------------- arguments

COMMAND=''
VAULT_ARG=''
CONFIG_ARG=''
TAG=''
MANY=0
CLI=''
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)  usage; exit 0 ;;
        -v|--vault) [ $# -ge 2 ] || usage_error "$1 needs a vault path or name"
                    VAULT_ARG=$2; shift 2 ;;
        -c|--config-folder)
                    [ $# -ge 2 ] || usage_error "$1 needs a folder name, such as .obsidian"
                    valid_config_dir "$2" ||
                        usage_error "not a config folder name: $2; it starts with a dot and has no / \\ or :"
                    CONFIG_ARG=$2; shift 2 ;;
        -*)         usage_error "unknown option: $1" ;;
        *)          [ -z "$COMMAND" ] || usage_error "one command at a time, not $COMMAND and $1"
                    COMMAND=$1; shift ;;
    esac
done

case "$COMMAND" in
    install|uninstall|status|save|check) ;;
    '') usage_error "no command given" ;;
    *)  usage_error "unknown command: $COMMAND" ;;
esac

for tool in osascript security launchctl; do
    have "$tool" || die "$tool not found; obsidian-sync-guard only works on macOS"
done
tab=$(printf '\t')

if [ "$COMMAND" = uninstall ]; then
    VAULT_PATH=''
    # A vault Obsidian has dropped, as it does one whose folder is missing
    # when it starts, is still found by the path it had.
    if [ -n "$VAULT_ARG" ] && ! find_vault "$VAULT_ARG"; then
        case "$VAULT_ARG" in
            /*) VAULT_PATH=${VAULT_ARG%/} ;;
            *)  exit 1 ;;
        esac
    fi
    cmd_uninstall
    exit 0
fi

# -------------------------------------------------------------------- vault

[ -f "$OBSIDIAN_CONFIG" ] || die "no vault list at $OBSIDIAN_CONFIG; has Obsidian run on this Mac?"

# With no vault named, every guarded vault, each with the config folder its
# agent guards. Each runs in a subshell, so one that fails or exits leaves
# the rest to run.
if [ -z "$VAULT_ARG$CONFIG_ARG" ] && [ "$COMMAND" != install ] &&
   guarded=$(guards) && [ -n "$guarded" ]; then
    MANY=1
    rc=0
    gap=''
    while IFS=$tab read -r file vault dir; do
        [ "$COMMAND" != status ] || printf '%s' "$gap"
        gap='
'
        ( find_vault "$vault" && CONFIG_DIR=$dir && "cmd_$COMMAND" ) </dev/null || rc=1
    done <<EOF
$guarded
EOF
    exit "$rc"
fi

find_vault "$VAULT_ARG" || exit 1
CONFIG_DIR=$CONFIG_ARG
if [ -z "$CONFIG_DIR" ]; then
    CONFIG_DIR=$(find_config_dir) || exit 1
fi

"cmd_$COMMAND"
