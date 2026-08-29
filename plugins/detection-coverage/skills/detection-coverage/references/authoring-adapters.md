# Writing an adapter

An adapter is one markdown file plus one entry in `adapters.yaml`. There is no code API,
because the model is the runtime — the file tells Claude how to read a kind of input, or how
to render a kind of output, and that is the whole mechanism.

The test of a correct adapter: adding it requires **no change to `SKILL.md`**. If the core
workflow needs to know your adapter exists beyond its registry entry, the abstraction has
leaked and the adapter needs rethinking.

## Input adapters

File: `references/inputs/<id>.md`. Structure it as:

1. **What this reads** — file patterns, formats, where it looks by default.
2. **What to extract** — concrete, in the vocabulary of the ledger. Which sections it
   populates, and what a good entry looks like.
3. **How to derive failure modes from it** — the reasoning specific to this input type. This
   is the part with actual content; the rest is plumbing.
4. **Source ref convention** — how to cite evidence from this input (`file:line`,
   `doc.md#anchor`, `rule-id`). Every entry needs one.
5. **Confidence guidance** — what this input type justifies. A threat model entry is high
   confidence because a human already reasoned about it. A failure mode inferred from a code
   pattern usually is not.

An input adapter must never invent. If it cannot cite, it does not emit.

## Output adapters

File: `references/outputs/<id>.md`. Structure it as:

1. **Selection** — which `detection_class` values and log source types it serves. Copy this
   into `serves_classes` / `serves_sources` in the registry so selection is mechanical. Use
   a `selector` expression for conditional adapters (see `instrumentation`).
2. **Artifact layout** — filenames, directory structure, one artifact per signal or grouped.
3. **Template** — a complete, working example with every field filled. Templates teach far
   better than field lists; write one you would be happy to ship.
4. **Field mapping** — ledger field → target platform field, explicitly. Especially severity
   and dedup, which every platform names differently.
5. **Tests** — what fixtures ship with the artifact, in the platform's native format if it
   has one.
6. **Idempotency** — how a re-run recognizes its own prior output and leaves human edits
   alone. Generated artifacts carry a header comment with the signal ID and a
   `detection-coverage: generated` marker; if that marker is absent or the body has
   diverged, the file was edited by a human and must not be overwritten.

## Registering

Add to `adapters.yaml` under `inputs:` or `outputs:`. Then enable it in the target repo's
`detection-coverage.yaml`. Adapters absent from that config are never read — which is the
point of the registry, since reading every adapter file on every run would waste most of the
context on formats that are not in use.

## Testing a new adapter

Run against `examples/price-oracle/` with only your adapter and `report` enabled. Check:

- it emits nothing for signals it does not serve
- every entry it emits carries a `source_ref` that actually resolves
- a second run produces zero diff
- a hand-edited artifact survives a re-run untouched
