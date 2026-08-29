#!/usr/bin/env python3
"""Diff two Coverage Ledgers and report what changed.

This is deterministic on purpose. Hand-diffing a hundred signals is exactly the kind of
work a model should not be doing, and the report's credibility depends on the delta being
exact rather than approximately right.

Categories:
  new       a failure mode or signal that did not exist in the previous run
  resolved  present before, gone now, or moved from uncovered to covered
  drifted   same entry, but its content or coverage status changed
  stale     marked stale in the current ledger; its artifacts should be removed

Usage:
    diff_ledger.py PREVIOUS CURRENT [--format markdown|json]
"""

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

# Fields whose change means the mapping needs fresh eyes. Cosmetic edits to a description
# are not worth a delta entry; a changed severity or detection logic is.
MATERIAL_FM = ("title", "severity", "category", "status", "source_refs")
MATERIAL_SIG = ("posture", "detection_class", "detection_logic", "fidelity", "observable")


def load(path):
    return yaml.safe_load(Path(path).read_text()) or {}


def index(ledger, section):
    return {e["id"]: e for e in (ledger.get(section) or []) if e.get("id")}


def coverage_index(ledger):
    return {c["signal_id"]: c for c in (ledger.get("coverage") or []) if c.get("signal_id")}


def changed_fields(old, new, fields):
    return [f for f in fields if old.get(f) != new.get(f)]


def diff(prev, curr):
    prev_fm, curr_fm = index(prev, "failure_modes"), index(curr, "failure_modes")
    prev_sig, curr_sig = index(prev, "signals"), index(curr, "signals")
    prev_cov, curr_cov = coverage_index(prev), coverage_index(curr)

    out = {"new": [], "resolved": [], "drifted": [], "stale": []}

    for fid, fm in curr_fm.items():
        if fid not in prev_fm:
            out["new"].append({"kind": "failure_mode", "id": fid, "title": fm.get("title"),
                               "severity": fm.get("severity"), "detail": "newly identified"})
        elif fm.get("status") != "stale":
            # A newly stale entry is reported once, below, rather than also as a drift
            # of the status field that made it stale.
            fields = changed_fields(prev_fm[fid], fm, MATERIAL_FM)
            if fields:
                out["drifted"].append({"kind": "failure_mode", "id": fid, "title": fm.get("title"),
                                       "severity": fm.get("severity"),
                                       "detail": "changed: " + ", ".join(fields)})
        if fm.get("status") == "stale":
            out["stale"].append({"kind": "failure_mode", "id": fid, "title": fm.get("title"),
                                 "severity": fm.get("severity"),
                                 "detail": "source anchor gone; generated artifacts should be removed"})

    for fid, fm in prev_fm.items():
        if fid not in curr_fm:
            out["resolved"].append({"kind": "failure_mode", "id": fid, "title": fm.get("title"),
                                    "severity": fm.get("severity"), "detail": "no longer present"})

    for sid, sig in curr_sig.items():
        title = sig.get("observable", "")[:70]
        now = (curr_cov.get(sid) or {}).get("status")
        if sid not in prev_sig:
            out["new"].append({"kind": "signal", "id": sid, "title": title,
                               "severity": now, "detail": f"new signal, coverage: {now}"})
            continue
        before = (prev_cov.get(sid) or {}).get("status")
        if before != now:
            # Closing a gap is the outcome the whole tool exists for -- report it as
            # resolved rather than burying it among the drifts.
            bucket = "resolved" if now == "covered" and before != "covered" else "drifted"
            out[bucket].append({"kind": "signal", "id": sid, "title": title, "severity": now,
                                "detail": f"coverage {before} -> {now}"})
        else:
            fields = changed_fields(prev_sig[sid], sig, MATERIAL_SIG)
            if fields:
                out["drifted"].append({"kind": "signal", "id": sid, "title": title, "severity": now,
                                       "detail": "changed: " + ", ".join(fields)})

    for sid, sig in prev_sig.items():
        if sid not in curr_sig:
            out["resolved"].append({"kind": "signal", "id": sid,
                                    "title": sig.get("observable", "")[:70],
                                    "severity": None, "detail": "signal no longer mapped"})
    return out


def render_markdown(delta, prev_run, curr_run):
    total = sum(len(v) for v in delta.values())
    if not total:
        # A periodic report that emits the same wall of text every week teaches people to
        # skip it. Staying quiet is what earns attention when there is something to say.
        return f"No change since {prev_run or 'the previous run'}.\n"

    headings = {
        "new": ("New", "Identified for the first time in this run."),
        "resolved": ("Resolved", "Closed, covered, or no longer present."),
        "drifted": ("Drifted", "Still present, but changed materially - re-check the mapping."),
        "stale": ("Stale", "Source anchor is gone; generated artifacts should be removed."),
    }

    lines = [f"Comparing `{prev_run or 'previous'}` -> `{curr_run or 'current'}`.", ""]
    for key in ("new", "drifted", "stale", "resolved"):
        rows = delta[key]
        if not rows:
            continue
        title, blurb = headings[key]
        lines += [f"### {title} ({len(rows)})", "", blurb, "",
                  "| Kind | ID | What | Detail |", "|---|---|---|---|"]
        for r in rows:
            what = (r.get("title") or "").replace("|", "\\|").strip()
            sev = f" _{r['severity']}_" if r.get("severity") else ""
            lines.append(f"| {r['kind']} | `{r['id']}` | {what}{sev} | {r['detail']} |")
        lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("previous", type=Path)
    ap.add_argument("current", type=Path)
    ap.add_argument("--format", choices=["markdown", "json"], default="markdown")
    args = ap.parse_args()

    prev = load(args.previous) if args.previous.exists() else {}
    curr = load(args.current)
    delta = diff(prev, curr)

    if args.format == "json":
        print(json.dumps(delta, indent=2))
    else:
        print(render_markdown(delta,
                              (prev.get("run") or {}).get("id"),
                              (curr.get("run") or {}).get("id")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
