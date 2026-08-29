# detection-coverage

A Claude Code plugin that walks from *"what can go wrong with this system"* to *"here is the
rule that would catch it"* — and can be re-run as the system changes.

Most monitoring is built bottom-up: someone notices a log source exists and writes a rule for
whatever happens to be visible in it. Coverage built that way looks healthy on a dashboard
and has holes exactly where the design's real assumptions live. This plugin goes the other
direction.

## What it does

Given a target repo, it reads the codebase, design docs, threat model and the existing
alert/rule inventory; derives failure modes; maps each to signals split into **leading**
(early warning, while the bad thing is still assembling) and **lagging** (indicators that it
already happened); reconciles those against what is already monitored; and generates the
detections that close the gaps.

Where nothing can observe a failure mode, it says so and emits an **instrumentation
proposal** — the log event the application must start emitting — instead of a rule that could
never fire. That case is usually the most valuable output of a run: most "detection gaps" are
observability gaps wearing a costume.

## Install

```
/plugin marketplace add brodieve/utilities
/plugin install detection-coverage
```

Then run `/detection-coverage` in the repo you want analysed.

## Extending it

Input and output adapters never talk to each other — they both talk to a **Coverage Ledger**,
a committed YAML file that is the single intermediate representation.

```
inputs/*  ──►  derive  ──►  Coverage Ledger  ──►  reconcile  ──►  outputs/*
```

Adding an adapter is one markdown file plus one line in `references/adapters.yaml`. Nothing
in `SKILL.md` changes — if it needs to, the abstraction has leaked. See
`skills/detection-coverage/references/authoring-adapters.md`.

**Inputs**: `codebase`, `design-doc`, `threat-model`, `signal-inventory`
**Outputs**: `panther`, `cloudwatch`, `wiz`, `instrumentation`, `report`

## Why the ledger is committed

Stable IDs plus the previous ledger let run N+1 report a *delta* — new gaps, resolved gaps,
mappings that drifted because the code beneath them changed, rules gone stale because the
code they watch was deleted — rather than regenerating everything and burying the signal. A
re-run over an unchanged target produces an empty delta and zero artifact churn, which is
enforced by the test suite: a periodic tool that rewrites its own output every run trains
everyone to ignore its PRs.

## Configuration

Put `detection-coverage.yaml` in the target repo — see
`examples/price-oracle/detection-coverage.yaml` for a complete one. Without it the skill runs
in discovery mode, proposes a config, and asks before writing anything.

## Layout

```
skills/detection-coverage/
├── SKILL.md                  the five-stage workflow
├── references/
│   ├── detection-engineering.md   doctrine: leading vs lagging, the six detection
│   │                              classes, how a log line becomes an alert
│   ├── ledger-schema.md           the intermediate representation
│   ├── adapters.yaml              the registry
│   ├── authoring-adapters.md      how to add one
│   ├── inputs/  outputs/          the adapters
│   └── examples/crypto-price-monitor.md   one failure mode, end to end
├── schema/ledger.schema.json
└── scripts/
    ├── ledger.py             validate; assign deterministic IDs
    └── diff_ledger.py        new / resolved / drifted / stale
examples/price-oracle/        fixture target with known-correct answers
tests/run_tests.sh            manifest, registry, ledger, delta and template tests
```

## Tests

```
bash tests/run_tests.sh
```

Requires `python3` and PyYAML; `jsonschema` and `python-hcl2` add structural validation when
present. The suite checks the manifests, registry integrity, ledger validation (including six
ledgers that must be *rejected*), ID determinism, delta classification, and whether the
templates in the output adapter docs are genuinely valid artifacts — the Panther rule is
executed against its own fixtures rather than merely inspected.

## Nothing ships automatically

Generated detections are a proposal on a branch, for human review. Anything that can page a
person at 3am gets read by a person first.
