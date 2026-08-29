# Input adapter: design-doc

## What this reads

Markdown, plain text and PDF design or architecture documents at the paths configured in
`detection-coverage.yaml` (typically `docs/design/*.md`, `docs/architecture/*.md`, RFCs,
ADRs). PDFs: extract text first.

## What to extract

Populates `assets` and `failure_modes`.

- **Components and data flows** — the system as it was intended, which is often not the
  system in the code. Where the document and the code disagree, that gap is itself worth
  recording as a failure mode: the design's controls may not exist.
- **Trust boundaries** — stated explicitly in most design docs, and usually the single most
  useful thing in them.
- **Assumptions** — see below.
- **Explicit non-goals** — "we do not defend against a malicious insider" is a scoping
  decision, not an absence of risk. Record it, at the severity it deserves, so the choice is
  visible rather than forgotten.

## Assumptions are the richest vein

Design documents state assumptions that the code then silently depends on:

- "We assume the exchange API returns honest prices."
- "We assume this queue is only writable by our own services."
- "We assume clock skew between nodes is under one second."
- "We assume the upstream service validates the payload before forwarding."
- "Rate limiting is handled at the edge."

**Every one of these is a failure mode the moment it stops being true**, and they are
systematically under-monitored, for a structural reason: the document that states them is
written once, filed, and never read by whoever builds the monitoring. Nobody ever writes an
alert for an assumption, because assumptions do not appear in logs — they appear in the
absence of anything checking them.

Hunt them deliberately. Search for: *assume, assumption, expects, relies on, trusted,
guaranteed, out of scope, we do not, should never, invariant, must always*.

For each, write the failure mode as the **negation**, and set
`provenance: design_doc_assumption`. Then ask the question that produces the signal: *if this
assumption became false, what would be different in telemetry?* Very often the answer is a
divergence check or a plausibility check that nobody has ever implemented — which is exactly
the leading signal the system lacks.

## Source ref convention

`docs/design/oracle.md#assumptions` — the heading anchor containing the statement. If the
document has no headings, use `docs/design/oracle.md:L42`.

## Confidence guidance

- Explicit stated assumption → `high` confidence. The author told you the load-bearing
  belief; you are only negating it.
- Inferred from a data flow diagram or prose description → `medium`.
- Where the document describes a component you could not find in the code → `low` on the
  failure mode, but record the design/code divergence separately. Stale documentation is
  worth knowing about on its own.
