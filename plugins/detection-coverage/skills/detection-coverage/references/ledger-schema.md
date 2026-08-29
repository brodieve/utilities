# The Coverage Ledger

The ledger is the single intermediate representation between input adapters and output
adapters. It is YAML, committed to the target repo (default `detections/ledger.yaml`), and
validated against `schema/ledger.schema.json`.

Committing it is deliberate: it is what turns a one-shot analysis into something that can be
re-run. The previous ledger is an input to the next run.

## Sections

| Section | Holds |
|---|---|
| `run` | Provenance for this run: id, timestamp, target, commit, adapters used |
| `assets` | What exists and is worth protecting |
| `failure_modes` | What can go wrong |
| `log_sources` | Where evidence could come from, and whether it exists today |
| `signals` | What would be observably different, per failure mode |
| `coverage` | Whether each signal is already handled |
| `outputs` | Which artifacts this run produced, and for which signals |

## Example

```yaml
run:
  id: 2026-08-29T14-02-11Z
  timestamp: "2026-08-29T14:02:11Z"
  target: price-oracle
  target_commit: a1b2c3d
  adapters_used: [codebase, design-doc, threat-model, signal-inventory, panther, cloudwatch, report]

assets:
  - id: AS-price-feed
    kind: external_dep
    name: Exchange price feed
    description: Public REST endpoints polled for spot prices across configured exchanges.
    source_refs: ["src/feed.py:12", "docs/design/oracle.md#data-sources"]

failure_modes:
  - id: FM-stale-exchange-price
    title: Oracle trades on a stale or manipulated exchange price
    description: >
      A configured exchange returns a price that is wrong - manipulated by a thin-book
      attack, or simply stale because the venue is degraded - and the oracle publishes it
      without cross-checking.
    category: data_integrity
    assets: [AS-price-feed]
    attack_narrative: >
      Attacker moves the price on the thinnest configured venue. The poller reads it,
      finds no cross-venue check, and publishes. Downstream contracts settle against
      the bad price before anyone notices.
    provenance: design_doc_assumption
    source_refs: ["docs/design/oracle.md#assumptions", "src/feed.py:88"]
    severity: high
    confidence: high
    status: active

log_sources:
  - id: LS-price-poller
    name: /aws/lambda/price-poller
    type: cloudwatch_log_group
    status: present
    fields: [pair, exchange, price, ts, latency_ms]
    source_refs: ["src/feed.py:44"]

signals:
  - id: SIG-price-divergence-cross-exchange
    failure_mode: FM-stale-exchange-price
    posture: leading
    observable: >
      The quoted price for a pair from one exchange diverges by more than N percent from
      the median across the other configured exchanges, for more than one poll interval.
    detection_class: anomaly_baseline
    telemetry:
      source_id: LS-price-poller
      fields: [pair, exchange, price, ts]
      exists: true
    detection_logic: >
      Group polls by (pair, 60s bucket). Compute median price across exchanges. Alert when
      any exchange deviates > 2% from that median in two consecutive buckets.
    fidelity: medium
    tuning_knob: divergence percentage and consecutive-bucket count
    time_to_detect: ~2 poll intervals

coverage:
  - signal_id: SIG-price-divergence-cross-exchange
    status: uncovered
    gap_reason: Existing alarms cover poller errors only, not price plausibility.

outputs:
  - path: detections/panther/price_divergence_cross_exchange.py
    adapter: panther
    signal_ids: [SIG-price-divergence-cross-exchange]
```

## ID stability

IDs are derived deterministically by `scripts/ledger.py --assign-ids`, from a normalized
slug of the entry's title plus a short hash of its first `source_ref`. The same failure mode
therefore keeps the same ID across runs, which is the whole basis of the delta report.

Do not hand-edit IDs. If a title changes materially, the ID changes and the entry shows in
the delta as one resolved plus one new — which is correct, because a materially different
statement of a failure mode deserves fresh eyes on its signals.

## Rules that the validator enforces

- Every `signals[].failure_mode` resolves to a `failure_modes[].id`.
- Every `signals[].telemetry.source_id` resolves to a `log_sources[].id`.
- Every `coverage[].signal_id` resolves to a `signals[].id`.
- Every signal has exactly one coverage entry.
- IDs are unique within their section and match their prefix pattern.
- Every `failure_modes[]` and `assets[]` entry has at least one `source_ref`.

That last one is enforced mechanically because it is the rule most likely to be skipped
under time pressure, and it is the rule that keeps the ledger honest.

## Statuses

`failure_modes[].status` is maintained across runs:

- `active` — source refs resolve, anchor content unchanged
- `drifted` — anchor content changed; signals need re-deriving
- `stale` — anchor gone; generated artifacts should be proposed for deletion

`coverage[].status` is `covered`, `partial`, `uncovered` or `unobservable`. Only `uncovered`
and `partial` generate detection artifacts; `unobservable` generates an instrumentation
proposal instead, and `covered` generates nothing at all.
