#!/usr/bin/env python3
"""Validate a Coverage Ledger and assign deterministic IDs.

Stable IDs are the basis of everything the skill does across runs: they are what lets
run N+1 report a delta instead of regenerating the world. They are derived from a
normalized slug of the entry's title plus a short hash of its first source_ref, so the
same failure mode keeps the same ID as long as its title and primary anchor hold.

Usage:
    ledger.py --validate LEDGER
    ledger.py --assign-ids [--write] LEDGER
    ledger.py --assign-ids --validate --write LEDGER
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

SCHEMA_PATH = Path(__file__).resolve().parent.parent / "schema" / "ledger.schema.json"

PREFIXES = {"assets": "AS", "failure_modes": "FM", "signals": "SIG", "log_sources": "LS"}

# Sections whose entries must cite the input that produced them. Enforced mechanically
# because it is the rule most likely to be skipped under time pressure, and the one that
# keeps the ledger from filling with plausible fiction.
REQUIRE_SOURCE_REFS = ("assets", "failure_modes")


def slugify(text, max_words=6):
    words = re.findall(r"[a-z0-9]+", (text or "").lower())
    return "-".join(words[:max_words]) or "unnamed"


def derive_id(section, entry):
    """Deterministic ID: prefix + title slug + 4 hex chars of the primary source ref.

    The hash disambiguates entries that slug identically but anchor to different places,
    without making the ID unreadable.
    """
    prefix = PREFIXES[section]
    name = entry.get("title") or entry.get("name") or ""
    refs = entry.get("source_refs") or []
    anchor = refs[0] if refs else name
    digest = hashlib.sha256(anchor.encode("utf-8")).hexdigest()[:4]
    return f"{prefix}-{slugify(name)}-{digest}"


def assign_ids(ledger):
    """Assign IDs to entries lacking them, rewriting references to match.

    Entries that already carry an ID keep it -- a human may have pinned one, and
    silently renaming it would break every artifact referencing it.
    """
    remap = {}
    for section, prefix in PREFIXES.items():
        for entry in ledger.get(section) or []:
            if entry.get("id"):
                continue
            new_id = derive_id(section, entry)
            placeholder = entry.get("_ref")
            if placeholder:
                remap[placeholder] = new_id
            entry["id"] = new_id
            entry.pop("_ref", None)

    if remap:
        for sig in ledger.get("signals") or []:
            fm = sig.get("failure_mode")
            if fm in remap:
                sig["failure_mode"] = remap[fm]
            tel = sig.get("telemetry") or {}
            if tel.get("source_id") in remap:
                tel["source_id"] = remap[tel["source_id"]]
        for cov in ledger.get("coverage") or []:
            if cov.get("signal_id") in remap:
                cov["signal_id"] = remap[cov["signal_id"]]
    return ledger


def _ids(ledger, section):
    return {e.get("id") for e in (ledger.get(section) or []) if e.get("id")}


def check_references(ledger):
    """Referential integrity -- the checks a JSON Schema cannot express."""
    errors = []

    for section in PREFIXES:
        seen = set()
        for entry in ledger.get(section) or []:
            eid = entry.get("id")
            if not eid:
                errors.append(f"{section}: entry {entry.get('title') or entry.get('name')!r} has no id")
            elif eid in seen:
                errors.append(f"{section}: duplicate id {eid}")
            else:
                seen.add(eid)

    for section in REQUIRE_SOURCE_REFS:
        for entry in ledger.get(section) or []:
            if not entry.get("source_refs"):
                errors.append(
                    f"{section}: {entry.get('id') or entry.get('title')} has no source_refs "
                    f"(every claim must cite the input that produced it)"
                )

    fm_ids = _ids(ledger, "failure_modes")
    ls_ids = _ids(ledger, "log_sources")
    sig_ids = _ids(ledger, "signals")

    for sig in ledger.get("signals") or []:
        sid = sig.get("id")
        if sig.get("failure_mode") not in fm_ids:
            errors.append(f"signals: {sid} references unknown failure_mode {sig.get('failure_mode')}")
        source_id = (sig.get("telemetry") or {}).get("source_id")
        if source_id not in ls_ids:
            errors.append(f"signals: {sid} references unknown log source {source_id}")

    covered = {}
    for cov in ledger.get("coverage") or []:
        sid = cov.get("signal_id")
        if sid not in sig_ids:
            errors.append(f"coverage: references unknown signal {sid}")
        covered[sid] = covered.get(sid, 0) + 1
        # A rule generated against telemetry that does not exist can never fire. Catching
        # this mechanically is the point: it is an easy mistake and an invisible one.
        if cov.get("status") in ("covered", "uncovered", "partial"):
            sig = next((s for s in ledger.get("signals") or [] if s.get("id") == sid), None)
            if sig and (sig.get("telemetry") or {}).get("exists") is False:
                errors.append(
                    f"coverage: {sid} is '{cov['status']}' but its telemetry does not exist "
                    f"-- must be 'unobservable' and routed to the instrumentation adapter"
                )

    for sid in sig_ids:
        n = covered.get(sid, 0)
        if n == 0:
            errors.append(f"coverage: signal {sid} has no coverage entry")
        elif n > 1:
            errors.append(f"coverage: signal {sid} has {n} coverage entries, expected 1")

    return errors


def check_schema(ledger):
    try:
        import jsonschema
    except ImportError:
        return ["(jsonschema not installed - skipped structural validation)"], True
    schema = json.loads(SCHEMA_PATH.read_text())
    validator = jsonschema.Draft7Validator(schema)
    errors = [
        f"schema: {'/'.join(str(p) for p in e.absolute_path) or '<root>'}: {e.message}"
        for e in sorted(validator.iter_errors(ledger), key=lambda e: list(e.absolute_path))
    ]
    return errors, False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ledger", type=Path)
    ap.add_argument("--validate", action="store_true", help="check schema and referential integrity")
    ap.add_argument("--assign-ids", action="store_true", help="derive IDs for entries lacking them")
    ap.add_argument("--write", action="store_true", help="write changes back to the ledger file")
    args = ap.parse_args()

    if not args.validate and not args.assign_ids:
        ap.error("nothing to do: pass --validate, --assign-ids, or both")

    ledger = yaml.safe_load(args.ledger.read_text()) or {}

    if args.assign_ids:
        ledger = assign_ids(ledger)
        if args.write:
            args.ledger.write_text(yaml.safe_dump(ledger, sort_keys=False, width=100, allow_unicode=True))
            print(f"wrote {args.ledger}")

    if args.validate:
        errors = []
        schema_errors, skipped = check_schema(ledger)
        if skipped:
            print(schema_errors[0], file=sys.stderr)
        else:
            errors += schema_errors
        errors += check_references(ledger)

        if errors:
            print(f"{len(errors)} problem(s) in {args.ledger}:", file=sys.stderr)
            for e in errors:
                print(f"  - {e}", file=sys.stderr)
            return 1
        n_fm = len(ledger.get("failure_modes") or [])
        n_sig = len(ledger.get("signals") or [])
        print(f"ok: {args.ledger} - {n_fm} failure modes, {n_sig} signals, references intact")

    return 0


if __name__ == "__main__":
    sys.exit(main())
