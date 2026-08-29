# Output adapter: cloudwatch

## Selection

- **Classes**: `threshold`, `absence_of_expected`
- **Sources**: `cloudwatch_log_group`, `metric`

CloudWatch is the right surface when the logic reduces to a number crossing a bound, or to
"this should have happened and didn't". A metric filter over a log group you already have
costs nothing to run and fires within a minute or two. Reaching for SIEM correlation when a
metric filter would do adds latency, cost, and a dependency on ingest keeping up.

Anything needing cross-event context, field-aware conditions or correlation belongs in
Panther instead.

## Artifact layout

```
<outputs.cloudwatch.dir>/
├── <signal_slug>.tf         # metric filter + alarm
└── <signal_slug>.pattern    # the raw filter pattern, for console use
```

Terraform is the default because it is the durable form — an alarm created by hand in the
console is invisible to the next run of this skill and to everyone else. Set
`outputs.cloudwatch.format: cli` for `aws` commands instead if the target does not use
Terraform.

## Template

`price_poller_heartbeat.tf` — an `absence_of_expected` signal:

```hcl
# detection-coverage: generated
# signal: SIG-price-poller-heartbeat-missing
# failure-mode: FM-price-poller-silently-dead
# source-refs: src/feed.py:120

resource "aws_cloudwatch_log_metric_filter" "price_poller_heartbeat" {
  name           = "price-poller-heartbeat"
  log_group_name = "/aws/lambda/price-poller"

  # Counts every successful poll cycle. The alarm fires on the absence of these.
  pattern = "{ $.event = \"poll_complete\" && $.status = \"ok\" }"

  metric_transformation {
    name          = "PricePollerHeartbeat"
    namespace     = "PriceOracle/Detection"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "price_poller_heartbeat_missing" {
  alarm_name        = "price-poller-heartbeat-missing"
  alarm_description = <<-EOT
    The price poller has not completed a successful cycle in 15 minutes. It runs every
    5 minutes, so this means it is dead, erroring before the completion log, or its log
    delivery has stopped. Downstream consumers will be reading an increasingly stale price
    without any error surfacing.
    Runbook: docs/runbooks/price-poller-down.md
  EOT

  namespace           = "PriceOracle/Detection"
  metric_name         = "PricePollerHeartbeat"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"

  # Critical for absence detection: without this the alarm sits in INSUFFICIENT_DATA
  # forever when the logs stop, which is exactly the condition it exists to catch.
  treat_missing_data = "breaching"

  alarm_actions = [var.detection_alert_topic_arn]
  ok_actions    = [var.detection_alert_topic_arn]
}
```

`price_poller_heartbeat.pattern`:

```
{ $.event = "poll_complete" && $.status = "ok" }
```

## Field mapping

| Ledger | CloudWatch |
|---|---|
| `signals[].id` | header comment, and the resource name |
| `signals[].observable` | `alarm_description`, first paragraph |
| `signals[].detection_logic` | filter `pattern` plus alarm thresholds |
| `signals[].tuning_knob` | `threshold` and `evaluation_periods` |
| `signals[].telemetry.source_id` | `log_group_name` |
| `signals[].telemetry.fields` | the JSON selectors in `pattern` |
| `failure_modes[].severity` | which SNS topic goes in `alarm_actions` |

## Getting `absence_of_expected` right

This is the class CloudWatch serves best and the one most often generated wrong. Three
things must all hold:

1. **`default_value = "0"`** on the metric transformation. Without it the metric emits no
   data points when nothing matches, rather than zeros, and there is nothing for the alarm
   to evaluate.
2. **`treat_missing_data = "breaching"`**. The default is `missing`, which parks the alarm in
   INSUFFICIENT_DATA when the logs stop — silently doing nothing in precisely the scenario
   the alarm was written for. This one setting is the difference between real coverage and
   an alarm that only looks like coverage.
3. **`evaluation_periods` × `period` comfortably exceeds the expected interval.** A job
   running every 5 minutes needs at least 3 periods of 300s, or ordinary jitter pages
   someone at 3am and the alarm gets muted within a week.

For a threshold signal, prefer `comparison_operator = "GreaterThanThreshold"` with
`treat_missing_data = "notBreaching"` — there, missing data genuinely means nothing bad
happened.

## Filter pattern syntax

Structured JSON logs use JSON selectors: `{ $.field = "value" && $.count > 10 }`. This
requires the application to emit JSON — if it emits formatted strings, the pattern degrades
to fragile substring matching that breaks the next time someone rewords a message. When that
is the situation, emit an instrumentation proposal for structured logging alongside the
filter, and note the fragility in `alarm_description`.

## Idempotency

Resource names derive from the signal slug, so a re-run targets the same resources rather
than creating duplicates. The `# detection-coverage: generated` marker governs overwrites
exactly as in the Panther adapter: marker present and body unchanged means regenerate;
marker present and body diverged means a human edited it, so report and leave alone; no
marker means the file is not ours.

## Verifying

`terraform fmt -check` and `terraform validate` on the output directory. Both should pass
before the artifacts are committed.
