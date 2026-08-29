# Input adapter: signal-inventory

## What this reads

Whatever record exists of monitoring that is already in place. Configure paths per source in
`detection-coverage.yaml`:

| Source | Form |
|---|---|
| Panther | A rule directory — `.py` rules with adjacent `.yml` metadata |
| CloudWatch alarms | JSON from `aws cloudwatch describe-alarms` |
| CloudWatch log groups | JSON from `aws logs describe-log-groups` / `describe-metric-filters` |
| Wiz | Exported controls JSON |
| Datadog, Splunk, other | Exported monitor or saved-search definitions |
| Hand-maintained | A YAML list of `{name, description, source, fires_on}` |

Inventory arrives as **exported files**, not live API calls. This keeps runs reproducible,
avoids needing production credentials in the loop, and means the run works offline. If no
export exists, say so plainly rather than assuming zero coverage — assuming nothing is
monitored produces a report that regenerates rules that already exist, which is the fastest
way to get the tool ignored.

## What to extract

### Log sources

Every log group, index, or stream referenced by an existing rule is a `log_sources` entry
with `status: present`. This is usually a more accurate picture of what is actually being
collected than anything in the code, because a rule that runs is proof the data arrives.

Record the fields each rule references — those fields demonstrably survive the whole
ingest pipeline, which is exactly the question the doctrine file says to ask before writing
any detection logic.

### Existing controls

For each rule, alarm or monitor, record enough to reconcile against:

- identifier, and the file or export it came from
- what it fires on, in plain language
- the log source and fields it depends on
- severity and routing, if declared
- whether it is enabled — a disabled rule is not coverage

## Reconciling

For each desired signal, find whether an existing control covers it, and assign:

- **`covered`** — an existing control fires on substantially this condition. Record its
  identifier in `existing_control`. **Generate nothing.** Silently regenerating rules that
  already exist is the failure mode that makes people stop reading the PRs.
- **`partial`** — something fires, but it misses cases the signal describes, is scoped to
  one resource when the risk is broader, is too noisy to be acted on, or is disabled.
  Propose a *specific amendment* to the existing rule, not a competing new one. Two rules
  covering the same ground with neither authoritative is worse than one imperfect rule.
- **`uncovered`** — the telemetry exists and nothing uses it. Generate.
- **`unobservable`** — determined by `telemetry.exists: false`, not by this adapter.

Match on *condition*, not on name. A rule called `suspicious-login` may or may not cover the
signal you are holding; read what it actually does. Name-matching produces both false
coverage (a gap you declared closed) and false gaps (a duplicate rule), and the first is the
dangerous one.

## Source ref convention

`detections/panther/aws_console_login.py` or `inventory/cloudwatch-alarms.json#PriceStale`.

## Confidence guidance

Not applicable — this adapter reports what exists rather than inferring. But be conservative
about declaring `covered`: an over-claimed coverage status hides a real gap behind a green
checkmark, and it will not be revisited, because the ledger is read back as fact on the next
run. When genuinely unsure, mark `partial` and explain the doubt in `gap_reason`.
