# Output adapter: panther

## Selection

- **Classes**: `sequence`, `allowlist_violation`, `anomaly_baseline`, `threshold`, `absence_of_expected`
- **Sources**: `cloudwatch_log_group`, `cloudtrail`, `app_json`, `k8s_audit`, `saas_audit`, `vpc_flow`

Panther is the right surface when the evidence lives in log events and the logic needs
context, correlation, or a field-aware condition. When the logic reduces to a count or a
number crossing a bound on a log group you already have, prefer CloudWatch — it is cheaper
and faster. See the routing table in `detection-engineering.md`.

Note that `anomaly_baseline` and `sequence` require state across events. Panther's streaming
rules are single-event; anything needing history must be expressed as a **scheduled query**
plus a scheduled rule. Say which you are generating, because they are deployed differently.

## Artifact layout

```
<outputs.panther.dir>/
├── <signal_slug>.py     # the rule
└── <signal_slug>.yml    # metadata and tests
```

## Template

`price_divergence_cross_exchange.py`:

```python
# detection-coverage: generated
# signal: SIG-price-divergence-cross-exchange
# failure-mode: FM-stale-exchange-price
# source-refs: docs/design/oracle.md#assumptions, src/feed.py:88
#
# Edits below this line are preserved across regeneration. Remove the
# "detection-coverage: generated" marker above to take full ownership of this file.

DIVERGENCE_THRESHOLD = 0.02  # tuning knob: fraction deviation from cross-venue median


def rule(event):
    median = event.deep_get("cross_venue", "median_price")
    price = event.get("price")
    if median is None or not price:
        return False
    return abs(price - median) / median > DIVERGENCE_THRESHOLD


def title(event):
    return (
        f"Price divergence: {event.get('exchange')} quoted {event.get('pair')} "
        f"{event.get('price')} vs cross-venue median "
        f"{event.deep_get('cross_venue', 'median_price')}"
    )


def dedup(event):
    return f"{event.get('exchange')}:{event.get('pair')}"


def alert_context(event):
    return {
        "pair": event.get("pair"),
        "exchange": event.get("exchange"),
        "price": event.get("price"),
        "median": event.deep_get("cross_venue", "median_price"),
        "ts": event.get("ts"),
        "runbook": "docs/runbooks/price-divergence.md",
    }
```

`price_divergence_cross_exchange.yml`:

```yaml
AnalysisType: rule
RuleID: PriceOracle.Divergence.CrossExchange
DisplayName: Price divergence across exchanges
Enabled: true
Filename: price_divergence_cross_exchange.py
LogTypes:
  - Custom.PriceOracle.Poll
Severity: High
Description: >
  One exchange is quoting a price materially away from the median of the other configured
  venues, which is what a thin-book manipulation or a stale feed looks like from here.
Runbook: docs/runbooks/price-divergence.md
Reference: docs/design/oracle.md#assumptions
DedupPeriodMinutes: 30
Threshold: 2
Tags:
  - detection-coverage
  - data_integrity
  - leading
Tests:
  - Name: Divergent price triggers
    ExpectedResult: true
    Log:
      pair: BTC-USD
      exchange: thinvenue
      price: 71000
      ts: "2026-08-29T14:00:00Z"
      cross_venue:
        median_price: 68000
  - Name: Normal spread does not trigger
    ExpectedResult: false
    Log:
      pair: BTC-USD
      exchange: bigvenue
      price: 68120
      ts: "2026-08-29T14:00:00Z"
      cross_venue:
        median_price: 68000
```

## Field mapping

| Ledger | Panther |
|---|---|
| `signals[].id` | header comment, and encoded in `RuleID` |
| `failure_modes[].severity` | `Severity` (`critical`→`Critical`, `high`→`High`, `medium`→`Medium`, `low`→`Low`, `info`→`Info`) |
| `signals[].observable` | `Description` |
| `signals[].detection_logic` | the `rule()` body |
| `signals[].tuning_knob` | a named module constant, not a literal buried in the expression |
| `signals[].telemetry.source_id` | `LogTypes` |
| `failure_modes[].source_refs` | `Reference` and the header comment |
| `signals[].fidelity` | `DedupPeriodMinutes` and `Threshold` — see below |

## Fidelity, dedup and threshold

Fidelity is not decoration; it must change the generated artifact:

- **high** — `DedupPeriodMinutes: 60`, `Threshold: 1`. Fires on a single occurrence.
- **medium** — `Threshold: 2` or more, so a lone blip does not page anyone.
- **low** — `Enabled: false` with a comment saying why, or route to a digest destination.
  Shipping a low-fidelity rule enabled is how alert fatigue starts, and one noisy rule
  discredits the whole generated set.

Always set `dedup()` to the entity the alert is *about* — the exchange and pair, the
principal, the resource. Defaulting to per-event dedup turns one incident into a hundred
alerts.

## Tests

Both fixtures are mandatory, in the `Tests:` block:

- `ExpectedResult: true` — the failure mode occurring
- `ExpectedResult: false` — realistic benign traffic

The negative fixture is the one that gets skipped and the one that matters. It is the only
durable record of what the author considered normal, and it is what a future maintainer
reads when the rule turns noisy.

Verify with `panther_analysis_tool test --path <dir>` when available.

## Idempotency

The `# detection-coverage: generated` marker on line 1 identifies files this adapter owns.
On a re-run: if the marker is present and the body matches what would be generated,
regenerate freely. If the marker is present but the body has diverged, a human edited it —
report the divergence in the coverage report and **do not overwrite**. If the marker is
absent, the file is not ours; leave it alone entirely.
