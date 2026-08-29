# Output adapter: instrumentation

## Selection

- **Classes**: all
- **Selector**: `telemetry.exists == false`

This adapter runs when a signal has no log source that can observe it. It is not a fallback —
it is the correct and only answer for that case.

A detection rule written against a field the application never emits is not coverage. It is a
file in a repo that looks like protection, passes review, shows green on a coverage
dashboard, and can never fire. Generating one is actively worse than generating nothing,
because it closes the ticket.

Most "detection gaps" in a real system are observability gaps wearing a costume. This adapter
is where the skill stops pretending otherwise, and it is frequently the most valuable output
of a run — it names blind spots that no amount of rule-writing would have found, because
rule-writing starts from the data that already exists.

## Artifact layout

```
<outputs.instrumentation.dir>/
└── <signal_slug>.md
```

Markdown, not code: the output is a proposal for a developer, and it needs to argue for
itself. It should read like a well-written ticket.

## Template

```markdown
<!-- detection-coverage: generated -->
<!-- signal: SIG-signing-key-use-unlogged -->
<!-- failure-mode: FM-signing-key-usable-by-unintended-principal -->

# Instrumentation needed: log every use of the oracle signing key

## Why

We want to detect the signing key being used by anything other than the poller
(`FM-signing-key-usable-by-unintended-principal`, severity **high**, from
`docs/design/oracle.md#signing`).

Right now that is not detectable at all. `src/signer.py:61` signs the payload and returns;
nothing is logged, so there is no record that a signature was ever produced, by whom, or
over what. If the key were misused, there would be no artifact of it anywhere — the first
sign would be a downstream consumer acting on a price we never published.

No rule can close this gap. The event has to exist first.

## The event to emit

Emit one structured event per signing operation:

| Field | Type | Notes |
|---|---|---|
| `event` | string | Constant `"payload_signed"` |
| `key_id` | string | Which key was used |
| `caller` | string | Principal or execution role that requested the signature |
| `payload_digest` | string | SHA-256 of the signed payload — **not** the payload |
| `pair` | string | Trading pair, for correlation with poll events |
| `ts` | string | RFC3339, UTC |

Do not log the payload or any key material. The digest is enough to correlate a signature
with what was published, which is all the detection needs.

## Where

`src/signer.py:61`, immediately after the signature is produced and before it is returned, so
that a signature that is produced but discarded is still recorded.

```python
signature = self._key.sign(payload)
log.info(
    "payload_signed",
    extra={
        "event": "payload_signed",
        "key_id": self._key_id,
        "caller": caller_identity(),
        "payload_digest": sha256(payload).hexdigest(),
        "pair": pair,
        "ts": utcnow_rfc3339(),
    },
)
return signature
```

This assumes the structured JSON logger already used at `src/feed.py:44`. If `caller_identity()`
does not exist, it needs adding — the caller is the field the detection actually turns on, so
without it this instrumentation does not unblock the rule.

## What this unblocks

Once the event ships, `SIG-signing-key-use-unlogged` becomes observable and this rule
becomes possible:

- **Class**: `allowlist_violation`
- **Source**: `/aws/lambda/price-oracle` (existing log group)
- **Logic**: alert when `event = "payload_signed"` and `caller` is outside the allowlist of
  known poller execution roles
- **Fidelity**: high — the allowlist is short and changes rarely
- **Surface**: CloudWatch metric filter on the log group (cheap, fast)

## Effort

Small: one log statement plus a helper, in a file the change already touches. No new
infrastructure, no new log group, no ingest change.
```

## What makes one of these good

**Name the field the detection turns on.** Vague asks ("add more logging here") get closed
without action. Specific ones ("this event, these six fields, at this line, because the rule
keys on `caller`") get merged.

**Show the rule it unblocks.** A developer asked to add a log line for abstract security
reasons will deprioritise it. One shown the exact alert it enables, and what goes undetected
until then, understands the trade they are making.

**Be honest about effort.** Distinguish a one-line addition to an existing logger from
"this component has no structured logging at all and needs it introduced". The second is a
real project and pretending otherwise wastes everyone's time.

**Never leak what you are trying to protect.** Digests, identifiers and counts, not payloads,
secrets, tokens or PII. An instrumentation proposal that creates a new exposure is a net
loss, and security tooling that causes a data incident is a bad look for the whole practice.

## Idempotency

Governed by the `<!-- detection-coverage: generated -->` marker. Once the instrumentation
lands and the field appears in the code, the next run's `codebase` adapter will set
`telemetry.exists: true`, this signal moves to `uncovered`, the real detection gets
generated, and this proposal is reported as resolved in the delta and removed. That
transition is the loop closing, and it is worth calling out explicitly in the report when it
happens — it is the clearest evidence the tool is working.
