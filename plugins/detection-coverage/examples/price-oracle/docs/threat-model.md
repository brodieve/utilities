# Threat model (abridged)

| ID | Threat | STRIDE | Component | Risk | Mitigation |
|---|---|---|---|---|---|
| T-01 | An attacker manipulates the price on a thin-book venue to move the published price | Tampering | feed | High | Config restricts which venues are polled |
| T-02 | The publish topic receives a forged price from another workload in the account | Spoofing | publisher | High | IAM policy on the topic |
| T-03 | The poller's exchange API credentials leak via logs | Information disclosure | feed | Medium | None documented |
