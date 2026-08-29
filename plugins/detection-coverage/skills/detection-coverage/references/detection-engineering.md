# Detection engineering doctrine

Read this before mapping failure modes to signals. It exists because the failure mode of
this skill is producing detection rules that look correct and cannot fire.

## 1. The pipeline is the constraint

A detection rule is the last link in a chain. Every link can drop the thing you need:

```
application code
  └─ emits a log statement          ← if the field isn't logged here, nothing downstream can save you
      └─ log group / stream / agent  ← sampling, truncation, dropped on backpressure
          └─ SIEM ingest             ← parsing failures silently discard malformed lines
              └─ normalized schema   ← custom fields get flattened into a blob or dropped
                  └─ detection rule  ← can only reference what survived
                      └─ alert       ← dedup, throttling, routing
                          └─ a human ← who has a finite attention budget
```

**A rule may only reference fields that survive this whole path.** Before writing any
detection logic, name the log source and the specific fields, and establish whether they
exist today. If they do not, the honest output is an instrumentation proposal — a change to
the application so the event exists at all — not a cleverer query against data nobody emits.

This is why the ledger has `telemetry.exists` and why `unobservable` is a first-class
coverage status. Most "coverage gaps" in real systems are actually *observability* gaps
wearing a costume.

The corollary, when reading an existing system: if you find a log statement, you have found
a detection opportunity. If you find a security-relevant decision with no log statement near
it, you have found a blind spot. Grep for the decisions, not the logs.

## 2. Leading and lagging

Split every failure mode's signals in two.

**Leading signals** fire while the bad thing is still assembling. They come from the
*steps* in the attack narrative, which is why writing the narrative in order matters:

- a precondition appearing — a new IAM principal granted a sensitive action, a key created,
  a peering connection opened
- a rate or ratio moving — authorization failures climbing on one endpoint as someone maps
  it, withdrawal velocity rising, a retry storm against one dependency
- a boundary softening — a security group opening, a bucket policy widening, TLS
  verification disabled in a config
- divergence between things that should agree — two exchanges quoting different prices, a
  replica drifting from its primary, a computed total disagreeing with a stored one

**Lagging signals** fire after. Funds moved, data left, the admin user exists.

Both are worth having. But coverage that is entirely lagging means you will only ever learn
about incidents in the past tense, and that is the normal state of most systems — which is
exactly why deliberately hunting for the leading half is where this skill earns its keep.

When only a lagging signal honestly exists, record that. A named gap beats an invented
early warning.

## 3. The six detection classes

Pick one per signal. The class determines which output surfaces can render it.

| Class | Fires when | Good for | Watch out for |
|---|---|---|---|
| `threshold` | A value crosses a fixed bound | Known-bad absolutes: >N failed logins, price outside sane range | Static bounds rot as the system grows |
| `anomaly_baseline` | A value deviates from its own recent history or from a peer | Volume, rate, divergence between sources | Needs a baseline window; noisy on seasonal data |
| `sequence` | Events occur in a specific order within a window | Multi-step attacks: create key → assume role → exfiltrate | Expensive; needs a correlation key present in every event |
| `absence_of_expected` | Something that should happen, doesn't | Dead cron jobs, silenced feeds, stalled pollers, missing heartbeats | See below — this is the one people forget |
| `allowlist_violation` | An actor or action outside a known-good set | Admin actions from unexpected principals, egress to unlisted destinations | Requires maintaining the allowlist, or it becomes noise |
| `config_drift` | Declared state diverges from actual state | Cloud posture, IAM, network boundaries | Drift is often legitimate; needs an exception path |

### On `absence_of_expected`

This class deserves special attention because it inverts the usual instinct and because
attackers and outages both produce silence.

If a job is meant to run every five minutes and stops, no rule that looks *for* events will
notice — there are no events. You need a rule that fires when the count of expected events
in a window is zero. The same shape catches: a log source that stopped shipping, a security
agent that was killed, a data feed a vendor quietly deprecated, a poller that has been
exiting on an unhandled exception for three weeks.

On CloudWatch this specifically requires setting `treat_missing_data = "breaching"` — the
default (`missing`) means the alarm will sit in INSUFFICIENT_DATA forever and never fire,
which is the exact failure this class exists to prevent. Getting this wrong produces an
alarm that looks like coverage and is not. On a SIEM, it needs a scheduled query rather than
a streaming rule, because streaming rules are driven by arriving events.

Any component that runs on a schedule, and any dependency you poll, should have an
`absence_of_expected` signal. Check for one every time.

## 4. Fidelity and the alert budget

Attention is the scarcest resource in the whole pipeline. A rule that fires fifty times a
week with a 2% true-positive rate does not add 2% of coverage; it subtracts from every other
rule by training people to close the tab.

For every signal record `fidelity` (`high`/`medium`/`low`) and, in `detection_logic`, the
knob that tunes it — the threshold, the window, the allowlist. A rule with no tuning knob
cannot be fixed when it turns out to be noisy, so it will be deleted or muted instead.

Route by fidelity:

- **high** — page or ticket. This is the only tier that should wake anyone.
- **medium** — ticket or daily digest.
- **low** — dashboard, report, or a hunting query. Still worth writing down; not worth
  interrupting anyone for.

If a signal is genuinely important but only achievable at low fidelity, that is a finding
in itself: it usually means the telemetry is too coarse, and the real fix is instrumentation.

## 5. Choosing the output surface

This routing table makes adapter selection non-arbitrary:

| The evidence lives in… | Class | Surface |
|---|---|---|
| Application or audit logs, correlated or contextual | `sequence`, `allowlist_violation`, `anomaly_baseline` | **Panther** |
| A log field reducible to a number, or a simple count | `threshold`, `absence_of_expected` | **CloudWatch** metric filter + alarm |
| Cloud resource configuration and posture | `config_drift`, `allowlist_violation` on resources | **Wiz** |
| Nowhere — `telemetry.exists: false` | any | **Instrumentation**, and only that |

Two rules of thumb:

**Prefer the cheapest surface that can express the logic.** A CloudWatch metric filter on a
log group you already have costs nothing to run and fires in a minute. Reaching for
stateful SIEM correlation when a metric filter would do adds latency, cost and a dependency
on ingest keeping up.

**One signal may legitimately produce more than one artifact.** A fast numeric threshold as
a CloudWatch alarm plus a richer correlated Panther rule over the same events is a normal
pairing — the alarm catches the blunt case in seconds, the rule catches the subtle case with
context. That is defence in depth, not duplication. Duplication is two rules with identical
logic in two systems where nobody knows which one is authoritative.

## 6. Every rule ships with a test

A detection nobody can prove fires is a detection nobody will dare change, and a rule nobody
dares change is a rule that rots in place.

Every generated rule carries at least:

- a **true positive** fixture — a synthetic event that must trigger it
- a **true negative** fixture — a realistic benign event that must not

The negative case is the one that gets skipped and the one that matters, because it encodes
what you decided was *normal*. Six months later, when the rule is noisy, the negative
fixture is the only record of what the author thought benign traffic looked like.

Where the target platform has a native test format (Panther's `rule_tests`), use it. Where
it does not, emit the fixtures alongside the artifact anyway.

## 7. Provenance, and how this skill fails

The characteristic failure of an LLM doing this work is fluent invention: a threat model
that reads beautifully and describes a system that does not exist, with rules referencing
fields nobody emits.

Three defences, applied without exception:

1. **Every ledger entry carries `source_refs`** pointing at a `file:line` or a document
   anchor. No reference, no entry. If a failure mode feels real but you cannot point at what
   in the input produced it, it belongs in a "candidates, unsourced" note for a human — not
   in the ledger.
2. **Every signal names its log source and fields**, with `exists` set from what was actually
   observed in the inputs, not from what would be convenient.
3. **`confidence` is recorded honestly.** A low-confidence entry with a real source reference
   is useful. A high-confidence entry that is wrong poisons every future run, because the
   next run treats the ledger as an input.

The ledger is read back on every subsequent run. Anything invented today is treated as
established fact tomorrow. That asymmetry is why the discipline is worth the friction.
