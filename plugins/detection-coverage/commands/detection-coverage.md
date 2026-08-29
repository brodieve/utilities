---
description: Map what can go wrong in this system to the signals that would reveal it, and generate the detections that catch it.
---

Run the `detection-coverage` skill against the current repository.

Arguments (all optional): `$ARGUMENTS`

- a path — analyse that directory as the target instead of the repo root
- `--dry-run` — produce the ledger and report, write no detection artifacts and no branch
- `--inputs a,b` / `--outputs a,b` — restrict to these adapters for this run
- `--full` — ignore the previous ledger and re-derive everything from scratch

Follow the workflow in the skill's SKILL.md. Read
`references/detection-engineering.md` before mapping signals — without it the output will be
plausible-looking rules that cannot fire.

If the target has no `detection-coverage.yaml`, run in discovery mode: infer what you can,
propose a config, and show it before writing anything.
