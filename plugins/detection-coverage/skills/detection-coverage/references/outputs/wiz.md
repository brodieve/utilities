# Output adapter: wiz

## Selection

- **Classes**: `config_drift`, `allowlist_violation` (on cloud resources)
- **Sources**: `wiz`, `cloudtrail`

Wiz is the right surface when the risk is a *state* rather than an *event*: a bucket that is
public, a role that can assume too much, a database without encryption, a security group open
to the world. These are conditions that persist, and posture evaluation finds them whether
or not anyone was watching when the change happened.

When you need to know *who changed it and when*, that is a CloudTrail event and belongs in
Panther. The two pair well: Wiz tells you the door is open, the CloudTrail rule tells you who
opened it. Where both are warranted, generate both.

## Artifact layout

```
<outputs.wiz.dir>/
└── <signal_slug>.yaml
```

## Template

```yaml
# detection-coverage: generated
# signal: SIG-oracle-key-role-overbroad
# failure-mode: FM-signing-key-usable-by-unintended-principal
# source-refs: docs/design/oracle.md#signing, infra/iam.tf:42

id: oracle-key-role-overbroad
name: Oracle signing key assumable by unintended principals
description: >
  The role permitted to use the oracle signing key should be assumable only by the poller's
  own execution role. Any wider trust policy means another workload in the account can sign
  prices, which is indistinguishable downstream from the oracle itself signing them.
severity: HIGH

target:
  cloudPlatform: AWS
  resourceType: IAM_ROLE
  scope:
    tag:
      key: component
      value: price-oracle

# Expected state. The control fails when a matched resource does not satisfy this.
expected:
  assumeRolePolicy:
    principals:
      allowlist:
        - arn:aws:iam::*:role/price-poller-execution
      denyWildcard: true
    conditions:
      required:
        - sts:ExternalId

remediation:
  description: >
    Restrict the trust policy to the poller execution role only, and remove any wildcard
    principal. If a second consumer genuinely needs signing, give it its own key rather than
    widening this one.
  reference: docs/runbooks/oracle-key-trust.md

metadata:
  detection_coverage_signal: SIG-oracle-key-role-overbroad
  posture: leading
  tags: [detection-coverage, authz, config_drift]
```

## Field mapping

| Ledger | Wiz control |
|---|---|
| `signals[].id` | `id`, and `metadata.detection_coverage_signal` |
| `signals[].observable` | `description` |
| `signals[].detection_logic` | `expected` predicate |
| `failure_modes[].severity` | `severity` (uppercased) |
| `failure_modes[].source_refs` | header comment, `remediation.reference` |
| `signals[].posture` | `metadata.posture` |

## Config drift needs an exception path

Drift is frequently legitimate. A control with no way to record "this one is intentional"
becomes a permanently-red row that everyone learns to scroll past, which is worse than not
having the control — it consumes attention and returns nothing.

Always scope the `target` as narrowly as the risk allows (tags, account, resource naming
convention) rather than evaluating every resource in the estate, and state in `remediation`
what a legitimate exception looks like so a reviewer can tell one from a finding.

## Schema caveat

Wiz control schemas vary by tenant configuration and change between versions. Treat the
template above as the *shape* — target selector, expected-state predicate, severity,
remediation — and reconcile field names against the tenant's own exported controls, which the
`signal-inventory` adapter will have read. Where an exported control exists, match its
conventions rather than this template's; a control that matches local convention is one a
human will actually merge.

If no export was available, note in the coverage report that these controls are structurally
correct but unvalidated against the tenant schema, rather than presenting them as ready to
apply.

## Idempotency

Governed by the `# detection-coverage: generated` marker, as in the other output adapters:
marker present and unchanged means regenerate, marker present and diverged means a human
edited it so report and leave alone, no marker means not ours.
