# Fixture: price-oracle

A deliberately small target for exercising the `detection-coverage` skill end to end. It is
not a real service. It exists so the skill's behaviour can be checked against a system whose
correct output is known:

- `docs/design/oracle.md` contains an explicit stated assumption, which the `design-doc`
  adapter must turn into a failure mode.
- `docs/threat-model.md` contains one entry with a documented mitigation, which must still
  produce a failure mode (a mitigation is not a detection).
- `src/feed.py` emits structured logs — so signals over it are observable.
- `src/signer.py` emits nothing — so any signal over signing must come back `unobservable`
  and route to the instrumentation adapter, never to a rule.
- `detections/panther/poller_errors.py` already exists, so its signal must come back
  `covered` and must not be regenerated.
- `src/feed.py` runs on a schedule, so an `absence_of_expected` signal is expected.
