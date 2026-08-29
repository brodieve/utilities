# Input adapter: codebase

## What this reads

Source files under the target repo, filtered by the `include` / `exclude` globs in
`detection-coverage.yaml`. Default excludes: tests, vendored dependencies, generated code,
lockfiles.

Do not read everything. Search for the patterns below, then read the surrounding function
for the ones that hit. On a large repo, budget attention toward code that handles money,
credentials, authorization, or untrusted input, and skip presentation layers.

## What to extract

Populates `assets`, `failure_modes` and `log_sources`.

### Assets

- **endpoints** — route definitions, handlers, RPC methods, message consumers
- **datastores** — database clients, cache clients, bucket and blob access
- **credentials** — secret reads, env var access, key material, token minting
- **jobs** — cron entries, scheduled lambdas, queue workers, timers
- **external_dep** — outbound HTTP clients, SDK clients, webhooks consumed
- **trust_boundary** — where untrusted input enters, where privilege changes

### Log sources

**Inventory every existing log statement.** This is not incidental — it defines what is
observable today, and therefore which signals can become rules and which must become
instrumentation proposals. For each, record the destination (log group, stdout collected by
an agent, a structured logger), the fields carried, and a `source_ref`.

A structured logger call with named fields is a far better detection substrate than a
formatted string, and the difference is worth noting in the ledger — a rule that has to
regex a message body is fragile and will break the next time someone rewords it.

## How to derive failure modes from code

Look for the *decision*, then ask what happens if it goes the other way.

| Pattern to find | Failure mode to consider | Category |
|---|---|---|
| Authorization check before a sensitive action | A path reaching that action without the check | `authz` |
| A handler with no authorization check at all | Unauthenticated access to it | `authz` |
| Value from an external API used without validation | The dependency lies, is stale, or is compromised | `data_integrity` |
| Money, balance, quantity, or price arithmetic | Rounding, sign, overflow, or replay producing a wrong amount | `fraud` |
| Retry or fallback logic | Fallback path skips a control the primary path applies | `authz`, `data_integrity` |
| Secret read from env or a manager | Secret logged, echoed in an error, or committed | `secrets` |
| Scheduled job or poller | It stops running and nobody notices | `availability` |
| Deserialization or template rendering of input | Injection or code execution | `abuse` |
| Client construction with TLS or auth options | Verification disabled, or credentials from an unexpected source | `misconfig` |
| Dependency manifest | A dependency is compromised or typosquatted | `supply_chain` |

Two derivations deserve extra weight because they are the ones bottom-up monitoring never
finds:

**Every scheduled job needs an `absence_of_expected` signal.** If it stops, no
event-driven rule will notice, because the absence of events is the symptom. Check for one
each time you record a `job` asset.

**Every external dependency is a trust assumption.** Code that takes a value from outside
and acts on it without a plausibility check has assumed that source is honest and healthy.
Write the failure mode for it being neither. This is the class the crypto price example
belongs to, and it is nearly always uncovered.

## Source ref convention

`path/to/file.py:88` — the line of the decision, not the line of the import. If a failure
mode spans several places, list the primary anchor first; `ledger.py` derives the entry's
stable ID from it, so put the most durable location first (a function definition outlasts a
line inside a loop body).

## Confidence guidance

Code inference is `medium` confidence by default.

Raise to `high` when the code makes the failure mode explicit — a `TODO` about the missing
check, a comment describing the assumption, an existing partial mitigation that shows
someone already knew.

Lower to `low` when the pattern matches but you cannot see the call graph well enough to
know whether the path is reachable. Emit it anyway with `confidence: low` — an unreachable
path is cheap for a human to dismiss, and a missed reachable one is not.
