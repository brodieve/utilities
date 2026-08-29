# Input adapter: threat-model

## What this reads

An existing threat model at the configured paths: a STRIDE table, an attack tree, a LINDDUN
or PASTA output, a spreadsheet export, or unstructured prose. Accept whatever form it is in
rather than demanding a schema — the value is in the thinking already done, not the format.

## What to extract

Populates `failure_modes` only. This adapter does not infer assets or log sources; it
converts.

Each threat entry becomes a failure mode:

| Threat model field | Ledger field |
|---|---|
| Threat / title | `title` |
| Description / scenario | `description` |
| Attack steps, kill chain | `attack_narrative` |
| STRIDE category | `category` (map below) |
| Affected component | `assets` (link to `AS-` ids if the codebase adapter found them) |
| Risk / impact rating | `severity` |
| Existing mitigation | note in `description`; do **not** treat as coverage |

### STRIDE mapping

| STRIDE | `category` |
|---|---|
| Spoofing | `authz` |
| Tampering | `data_integrity` |
| Repudiation | `data_integrity` |
| Information disclosure | `secrets` |
| Denial of service | `availability` |
| Elevation of privilege | `authz` |

Where an entry does not fit, prefer `abuse`, `fraud`, `misconfig` or `supply_chain` over
forcing it into a STRIDE bucket.

## Mitigations are not detections

A threat model that says "mitigated by input validation" has recorded a *control*, not a
signal. The failure mode still belongs in the ledger, and it still needs the question asked:
**if that mitigation failed or was bypassed, what would we see?**

This is the most common mistake when ingesting a threat model. A documented mitigation makes
a failure mode less likely; it does nothing to make it observable. Controls fail silently —
that is the entire reason detection exists as a discipline separate from prevention. Treat a
mitigated threat exactly like an unmitigated one for mapping purposes, and note the
mitigation as context that may inform severity.

## Source ref convention

`docs/threat-model.md#t-07` or `docs/threat-model.md:L112`. If entries carry their own IDs,
preserve the original ID in the description so a human can trace back to the source document.

## Confidence guidance

`high` by default. A human already reasoned about this and wrote it down; that is the
strongest input this skill receives.

Lower to `medium` when the threat model is visibly stale — it references components that no
longer exist in the code, or predates a major architectural change. Note the staleness in
the description rather than dropping the entry, since an old threat model is still evidence
of what the system was once believed to be.
