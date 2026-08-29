# Output adapter: report

## Selection

Always runs. Writes `<outputs.report.path>` (default `detections/COVERAGE.md`) and supplies
the PR body.

## Purpose

The report is what a human actually reads. Generated rules are reviewed in the diff; the
report is what tells them where to look and what it means. Optimize it for someone with five
minutes who wants to know what changed and what is still exposed — not for completeness.

## Structure

Use this template:

```markdown
# Detection coverage: <target>

_Run <run.id> against <target_commit>. Adapters: <adapters_used>._

## Summary

| | Count |
|---|---|
| Failure modes | 24 |
| Signals mapped | 41 (18 leading / 23 lagging) |
| Covered | 12 |
| Partial | 5 |
| Uncovered | 16 |
| **Unobservable** | **8** |

<One paragraph in plain language: the shape of the coverage and the single most
important thing to do about it.>

## Changes since last run

<Output of diff_ledger.py: new / resolved / drifted / stale. Omit the section entirely
when the delta is empty - say "No change since <previous run id>." and nothing else.>

## Not observable today

<First, because these cannot be fixed by writing rules and are the most commonly
missed finding. One row per unobservable signal: what we cannot see, which failure mode
it belongs to, and a link to the instrumentation proposal.>

| Failure mode | What we cannot see | Proposal |
|---|---|---|
| FM-signing-key-usable-by-unintended-principal (high) | Any use of the signing key | [instrumentation/signing-key-use.md](...) |

## Uncovered, by severity

<Table: failure mode, signal, posture, class, generated artifact. Ordered by severity,
then by leading before lagging - a leading signal is worth more than a lagging one at
equal severity.>

## Partial coverage

<Existing control, what it misses, and the specific amendment proposed. Never a
competing new rule.>

## Covered

<Collapsed list. Present for completeness and to show what was deliberately not
regenerated.>

## Failure modes with no signal

<Failure modes where no honest signal could be constructed. This section is a feature,
not an omission - it is the standing list of things that would go entirely unnoticed,
and it is where next quarter's observability work comes from.>

## Provenance

<Every failure mode with its source_ref, so a reviewer can check any claim against the
input that produced it. Keep terse; this is a lookup table, not prose.>
```

## Writing guidance

**Lead with what cannot be seen.** Everyone reports uncovered risks. Almost nobody reports
the risks that are structurally invisible, and those are the ones that matter most, because
no amount of rule-writing will surface them.

**Keep the delta section quiet when nothing changed.** A periodic report that produces the
same wall of text every week teaches people to skip it. An empty delta should render as one
line. The discipline of staying quiet is what earns attention when there is something to say.

**Never inflate.** Do not count a generated rule as coverage; it is a *proposal* until a
human merges it. The summary counts reflect the state of the world before this run's
artifacts land — otherwise the report congratulates itself for work nobody has reviewed.

**Every claim carries its `source_ref`.** The provenance section is what makes the report
auditable, and auditability is what makes it trusted on the fifth run rather than just the
first.

## PR body

Shorter than the report: the summary table, the delta, and the top five uncovered risks by
severity, with a link to the full report in the diff. A reviewer decides from the PR body
whether to read the diff, so it needs to convey what changed and how urgent it is in about
thirty seconds.
