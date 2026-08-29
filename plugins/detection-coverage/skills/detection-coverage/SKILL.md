---
name: detection-coverage
description: Map what can go wrong in a system to the signals that would reveal it, then generate the detections that catch it. Walks a codebase, design docs, threat models and the existing alert/rule inventory; derives failure modes; maps each to proactive early-warning signals and reactive indicators of compromise; reconciles against what is already monitored; and emits Panther SIEM rules, CloudWatch metric filters and alarms, Wiz config audit rules, application instrumentation proposals, and a coverage report. Use this skill whenever the user mentions detection coverage, detection engineering, threat-to-signal or threat-to-detection mapping, monitoring or alerting gaps, indicators of compromise, early warning signals, SIEM rules, Panther, Sigma, Wiz, CloudWatch alarms, "what would we detect if X happened", "are we monitoring this", auditing or reviewing existing detections, or wants alerting built for a service, script or feature they just described - even if they do not use the words "detection coverage".
---

# Detection Coverage

Most monitoring is written bottom-up: someone notices a log source exists and writes a rule
for whatever happens to be visible in it. Almost nobody walks the other direction — from
*"here is what can actually go wrong with this system"* to *"here is the signal that would
tell us, and here is the rule that fires on it."* Coverage built the first way looks healthy
on a dashboard and has holes exactly where the design's real assumptions live.

This skill walks the second direction, and is built to be re-run as the system changes.

## The contract

Input adapters and output adapters never talk to each other. They both talk to a
**Coverage Ledger** — a committed YAML file that is the single intermediate representation.

```
inputs/*  ──►  derive  ──►  Coverage Ledger  ──►  reconcile  ──►  outputs/*
```

That indirection is what makes the skill extensible: a new input (Terraform state, an
OpenAPI spec, incident post-mortems) or a new output (Datadog, Splunk, Sigma, Falco) is one
markdown file written against the ledger schema plus one line in the registry. Nothing in
this file changes. If you find yourself editing SKILL.md to add an adapter, the adapter is
wrong, not the skill.

The ledger being committed to the target repo is also what makes repeat runs useful. Stable
IDs plus the previous ledger let run N+1 report a *delta* — new gaps, resolved gaps,
mappings that drifted because the code beneath them changed, rules gone stale because the
code they watch was deleted — instead of regenerating everything and burying the signal.

## Before you start

Read `references/detection-engineering.md`. It is the doctrine: leading versus lagging
signals, the six detection classes, how a log statement actually becomes an alert, and how
to choose an output surface. Without it you will produce plausible-looking YAML that does
not correspond to anything that can fire. It is short, and it is the difference between this
skill working and this skill generating fiction.

If this is your first run against an unfamiliar target, also read
`references/examples/crypto-price-monitor.md` — one failure mode carried end to end into all
four output formats. It teaches the shape faster than any amount of abstract instruction.

## Configuration

The skill reads `detection-coverage.yaml` from the root of the **target** repo (the system
being analysed, which may or may not be the repo the plugin lives in). See
`references/adapters.yaml` for the registry of available adapters and
`examples/price-oracle/detection-coverage.yaml` for a complete config.

If no config exists, run in **discovery mode**: infer what you can from the repo, propose a
config, show it to the user, and get agreement before writing anything. Never silently
invent a target.

## The run

### 1. Collect

Load `references/adapters.yaml`, resolve which adapters are enabled, and read only those
adapter files. Run each enabled input adapter as described in its own reference file.

Every fact an input adapter produces carries `source_refs` — a `file:line` or a document
anchor. **A ledger entry with no source_refs is a hallucination and must be dropped.** This
is the single most important discipline in the skill: it is trivially easy to generate a
beautiful threat model that has nothing to do with the code in front of you, and the only
defence is that every claim points at the evidence that produced it.

### 2. Derive failure modes

Expand what the inputs gave you into the failure-mode set.

Threat model entries convert directly, at high confidence — someone already did this thinking.

Code and design docs are mined for what they *imply*. Look for trust boundaries, authorization
checks (and the paths that skip them), state-mutating and money-moving operations, external
dependencies, secret handling, scheduled jobs, and anything that parses untrusted input.

**Stated assumptions are the richest vein in any design document.** Every "we assume the
exchange API returns honest prices", "we assume this queue is only writable by us", "we
assume clock skew is under a second" is a failure mode the moment it stops being true — and
those are precisely the ones nobody writes rules for, because the document that states them
is filed away and never read by whoever builds the monitoring. Hunt them deliberately.

Categorize each: `authz`, `data_integrity`, `availability`, `supply_chain`, `misconfig`,
`secrets`, `fraud`, `abuse`. Write an `attack_narrative` — how it unfolds, in order. The
narrative is not decoration; the steps in it are where the leading signals come from.

Assign `severity` and `confidence` honestly. Low confidence is fine and useful; a
low-confidence failure mode with a cheap signal is still worth a rule. Overstated confidence
is what erodes trust in the whole output.

### 3. Map failure modes to signals

The core work. For each failure mode, ask: **what would be observably different in
telemetry?** Answer twice — before and after.

- **Leading** (`posture: leading`) — preconditions being assembled. A new principal granted a
  sensitive action; withdrawal velocity climbing; a config drifting permissive; error rates
  rising on an authorization path as someone probes it. These are the early warnings, and
  they are what most coverage lacks entirely.
- **Lagging** (`posture: lagging`) — the consequence. Funds moved; data left the boundary; the
  admin user exists now. Necessary, but if this is all you have, you are always reading about
  it afterwards.

Aim for at least one of each per failure mode where it is honestly possible. Where only a
lagging signal exists, say so — a gap you can name is worth more than a leading signal you
invented.

For every signal, fill in:

- `observable` — in prose, what is literally different in the telemetry. Concrete enough that
  someone could go look for it by hand.
- `detection_class` — one of the six (see the doctrine file). If it is
  `absence_of_expected`, be especially careful: that class is how you catch a killed cron
  job, a silenced feed, or a poller that died quietly, and it is the one most often missed.
- `telemetry` — the log source, the specific fields required, and **`exists: true|false`**.
- `detection_logic` — precise enough that an output adapter can render it without inventing
  anything: thresholds, windows, group-by keys, comparison baselines.
- `fidelity` — the expected false-positive burden, and what knob tunes it.
- `time_to_detect` — the honest latency, including poll and ingest delay.

Setting `telemetry.exists: false` is not a failure. It is the most valuable output the skill
produces, because it names a blind spot that no amount of rule-writing would have fixed.

### 4. Reconcile against existing coverage

Diff the desired signals against the inventory of controls that already exist. Each signal
lands in one of four states:

| Status | Meaning | What happens next |
|---|---|---|
| `covered` | An existing rule or alarm already fires on this | Nothing. Do not regenerate it. |
| `partial` | Something fires, but misses cases, or is too noisy to act on | Propose a specific amendment, not a replacement |
| `uncovered` | The telemetry exists, no rule uses it | Generate a detection |
| `unobservable` | No log source can see this at all | Instrumentation proposal, **never** a rule |

That last row is the one that matters most. A rule written against a field the application
never emits is not coverage — it is a rule that can never fire, sitting in a repo looking
like protection. When telemetry is missing, the answer is a code change, not a cleverer
query. Route it to the `instrumentation` adapter.

Respect `severity_floor` from the config: below it, record the gap in the ledger and the
report but do not generate artifacts. Volume is not the goal.

### 5. Emit

Validate and stabilize the ledger, then run the enabled output adapters over the gaps:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/detection-coverage/scripts/ledger.py" \
    --assign-ids --validate <ledger-path>
```

`ledger.py` derives deterministic IDs, so the same failure mode keeps the same ID across
runs, and rejects dangling references and duplicates. Run it before the adapters — an
invalid ledger produces invalid artifacts.

Each output adapter declares which signals it can serve. Select by `detection_class` and log
source type, using the routing table in the doctrine file. One signal may legitimately
produce artifacts in more than one system — a CloudWatch alarm for the fast numeric
threshold and a Panther rule for the correlated case is a normal pairing, not duplication.

Then compute the delta and write the report:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/detection-coverage/scripts/diff_ledger.py" \
    <previous-ledger> <current-ledger> --format markdown
```

Hand-diffing a hundred signals is exactly the kind of work a model should not be doing, and
the report's credibility depends on the delta being exact.

### 6. Deliver

Write artifacts to the configured directories, update the ledger, then:

1. Create branch `detection-coverage/<YYYY-MM-DD>` if not already on one.
2. Commit the ledger, artifacts and report together — they are one unit and are meaningless apart.
3. Open a PR whose body is the delta plus the top uncovered risks, ordered by severity.

**Nothing is auto-deployed.** Generated detections are a proposal for human review. Anything
that can page a person at 3am gets read by a person first.

## Re-running

On a repeat run, load the previous ledger first and treat it as an input:

- A failure mode whose `source_refs` still resolve and whose anchor content is unchanged
  carries forward untouched.
- A failure mode whose anchor **changed** is `drifted` — re-derive its signals; the code may
  have moved under the mapping.
- A failure mode whose anchor is **gone** is `stale` — flag its generated artifacts for
  deletion rather than silently leaving rules watching code that no longer exists.
- Human edits to generated artifacts are respected. If a rule carries an edit marker or has
  diverged from what this skill would generate, do not overwrite it; report the divergence
  and let the human decide.

A second run over an unchanged target must produce an empty delta and zero artifact churn.
If it does not, something in the pipeline is non-deterministic and that is a bug worth
chasing — a periodic tool that rewrites its own output every run is worse than no tool,
because it trains everyone to ignore its PRs.

## Reference map

| File | Read it when |
|---|---|
| `references/detection-engineering.md` | Always, before deriving signals |
| `references/ledger-schema.md` | Writing or reading the ledger |
| `references/adapters.yaml` | Every run — resolve which adapters are enabled |
| `references/inputs/*.md` | That input adapter is enabled |
| `references/outputs/*.md` | That output adapter is enabled |
| `references/authoring-adapters.md` | Adding or modifying an adapter |
| `references/examples/crypto-price-monitor.md` | First run, or the mapping stage feels abstract |
