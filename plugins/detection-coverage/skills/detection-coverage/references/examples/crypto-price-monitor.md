# Worked example: a crypto price monitor

One failure mode carried end to end, from a line in a design document to four artifacts.
Read this when the mapping stage feels abstract — the shape is easier to learn from one
complete example than from any amount of field-by-field instruction.

## The system

A scheduled job polls spot prices for a set of trading pairs from several exchanges,
publishes a price downstream, and emits structured JSON to a CloudWatch log group. A SIEM
(Panther) ingests that log group. This is a small, ordinary system — and it is worth noticing
how much of the interesting risk lives outside the code, in what it *trusts*.

## Step 1: the input gives you an assumption

`docs/design/oracle.md#assumptions` says:

> We assume the exchange APIs return honest, current prices.

The `design-doc` adapter finds this by searching for assumption language. It is one sentence
and the entire system rests on it, which is typical: the load-bearing beliefs are stated once,
in a document, and then never checked by anything.

## Step 2: negate it into a failure mode

```yaml
- id: FM-stale-exchange-price
  title: Oracle trades on a stale or manipulated exchange price
  category: data_integrity
  attack_narrative: >
    Attacker moves the price on the thinnest configured venue - cheap, on a small book.
    The poller reads it, applies no cross-venue check, and publishes. Downstream contracts
    settle against the bad price before anyone notices.
  provenance: design_doc_assumption
  source_refs: ["docs/design/oracle.md#assumptions", "src/feed.py:88"]
  severity: high
  confidence: high
```

The `source_refs` are what make this checkable rather than plausible. Anyone can verify it in
two clicks, and that is what makes the ledger trustworthy on the fifth run.

## Step 3: ask what would be different, twice

The narrative has steps, and the steps are where the leading signals come from.

**Leading** — while the price is wrong but before anything has settled against it. One venue
disagrees with the others. That divergence is visible in telemetry the moment it happens,
and it is visible *before* the consequence.

```yaml
- id: SIG-price-divergence-cross-exchange
  failure_mode: FM-stale-exchange-price
  posture: leading
  observable: >
    Quoted price for a pair from one exchange deviates more than 2% from the median across
    other configured exchanges, in two consecutive poll buckets.
  detection_class: anomaly_baseline
  telemetry: {source_id: LS-price-poller, fields: [pair, exchange, price, ts], exists: true}
  fidelity: medium
  tuning_knob: divergence percentage, consecutive-bucket count
  time_to_detect: ~2 poll intervals
```

**Lagging** — a downstream settlement executed at a price far off the market. Necessary, but
by the time it fires the money has moved.

**And the one people miss** — what if the poller simply *stops*? No event-driven rule will
notice, because the symptom is the absence of events. The last published price sits there
looking valid and grows quietly stale.

```yaml
- id: SIG-price-poller-heartbeat-missing
  failure_mode: FM-price-poller-silently-dead
  posture: leading
  observable: No successful poll cycle completed for 15 minutes on a 5-minute schedule.
  detection_class: absence_of_expected
  telemetry: {source_id: LS-price-poller, fields: [event, status], exists: true}
  fidelity: high
```

Every scheduled component in any system deserves this question. It is the cheapest signal in
detection engineering and among the most frequently absent.

## Step 4: reconcile

The `signal-inventory` adapter read the existing Panther rules and CloudWatch alarms. There
is an alarm on poller *error rate* — which fires when the poller throws, and does nothing at
all when the poller returns a confidently wrong price, or when it stops running cleanly.

- `SIG-price-divergence-cross-exchange` → **uncovered**
- `SIG-price-poller-heartbeat-missing` → **uncovered** (the error-rate alarm is not a
  heartbeat; zero errors and zero runs look identical to it)
- Poller throwing exceptions → **covered**, leave it alone

That third line matters as much as the first two. Regenerating a rule that already exists is
how a tool teaches people to stop reading its PRs.

## Step 5: route to surfaces

Using the routing table from the doctrine file:

| Signal | Class | Surface | Why |
|---|---|---|---|
| Cross-exchange divergence | `anomaly_baseline` | **Panther** | Needs a median across events — correlation |
| Poller heartbeat missing | `absence_of_expected` | **CloudWatch** | A count over a window; cheap and fast |
| Signing role too broad | `config_drift` | **Wiz** | A persistent state, not an event |
| Signing key use | — | **Instrumentation** | `telemetry.exists: false`; nothing logs it |

The fourth row is the one worth pausing on. We would like to alert on the signing key being
used by anything other than the poller — but nothing logs signing at all. There is no rule to
write. The honest output is an instrumentation proposal, and until it lands, this stays a
named blind spot rather than a file that looks like protection.

## Step 6: the artifacts

Full templates live in the output adapter files; in outline:

- **Panther** `price_divergence_cross_exchange.py` — `rule()` comparing price to cross-venue
  median, `dedup()` on `exchange:pair` so one bad venue is one alert, `DIVERGENCE_THRESHOLD`
  as a named constant because fidelity is medium and someone will need to tune it, plus a
  positive and a negative test fixture.
- **CloudWatch** `price_poller_heartbeat.tf` — a metric filter counting `poll_complete`
  events with `default_value = "0"`, and an alarm with `treat_missing_data = "breaching"`.
  Both settings are load-bearing: without them the alarm sits in INSUFFICIENT_DATA when the
  logs stop, which is exactly the case it exists to catch.
- **Wiz** `oracle-key-role-overbroad.yaml` — expected trust policy for the signing role.
- **Instrumentation** `signing-key-use.md` — the `payload_signed` event, its six fields, the
  line in `src/signer.py` where it belongs, and the allowlist rule it unblocks.

## What this example is really teaching

The interesting risk in this system is not a bug in the code. It is that the code **trusts
something outside itself** and never checks the trust. No amount of reading `feed.py` for
vulnerabilities finds it; you find it by reading the design document's assumptions and asking
what happens when one is false.

Then, separately: two of the four artifacts here exist only because someone asked "what if
this stops" and "what if nothing logs this". Those two questions produce a large share of the
value in any run of this skill, and neither is answerable by looking at existing log data —
which is precisely why bottom-up monitoring never finds them.
