#!/usr/bin/env bash
# Test suite for the detection-coverage plugin.
#
# Covers the parts that must be deterministic: manifest validity, registry integrity,
# ledger validation (positive and negative), ID stability, the delta report, and whether
# the templates in the output adapter docs are actually valid artifacts rather than
# plausible-looking prose.
#
# Requires: python3, PyYAML. Optional: jsonschema, python-hcl2, terraform.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
SKILL="$ROOT/skills/detection-coverage"
FIX="$ROOT/tests/fixtures"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { echo "  [PASS] $1"; pass=$((pass+1)); }
bad()  { echo "  [FAIL] $1"; fail=$((fail+1)); }
check() { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

echo "== manifests =="
python3 -c "
import json,sys
for p in ['$ROOT/../../.claude-plugin/marketplace.json','$ROOT/.claude-plugin/plugin.json']:
    json.load(open(p))
m = json.load(open('$ROOT/../../.claude-plugin/marketplace.json'))
assert m.get('name') and m.get('owner',{}).get('name') and m.get('plugins'), 'marketplace missing required fields'
src = m['plugins'][0]['source']
assert src.startswith('./'), 'relative source must start with ./'
import os
assert os.path.isdir(os.path.join('$ROOT/../..', src)), f'source path {src} does not exist'
p = json.load(open('$ROOT/.claude-plugin/plugin.json'))
assert p.get('name') and p['name'].islower(), 'plugin name must be present and kebab-case'
" 2>&1 | sed 's/^/    /'
check $? "marketplace.json and plugin.json valid and consistent"

echo "== adapter registry =="
python3 -c "
import yaml, os, sys
reg = yaml.safe_load(open('$SKILL/references/adapters.yaml'))
missing = [a['ref'] for group in ('inputs','outputs') for a in reg[group]
           if not os.path.exists(os.path.join('$SKILL/references', a['ref']))]
if missing: sys.exit('missing adapter files: ' + ', '.join(missing))
n = sum(len(reg[g]) for g in ('inputs','outputs'))
print(f'{n} adapters registered, all reference files present')
" 2>&1 | sed 's/^/    /'
check $? "every registered adapter has its reference file"

echo "== ledger: positive =="
python3 "$SKILL/scripts/ledger.py" --validate "$FIX/ledger-v1.yaml" >/dev/null 2>&1
check $? "ledger-v1 validates"
python3 "$SKILL/scripts/ledger.py" --validate "$FIX/ledger-v2.yaml" >/dev/null 2>&1
check $? "ledger-v2 validates"

echo "== ledger: negative (each must be rejected) =="
python3 - "$FIX/ledger-v1.yaml" "$TMP" <<'PY'
import yaml, copy, sys
base = yaml.safe_load(open(sys.argv[1])); out = sys.argv[2]
def w(name, mut):
    d = copy.deepcopy(base); mut(d)
    yaml.safe_dump(d, open(f"{out}/{name}.yaml", "w"), sort_keys=False)
w("dangling",     lambda d: d['signals'][0].__setitem__('failure_mode', 'FM-nope-0000'))
w("dupe",         lambda d: d['failure_modes'][1].__setitem__('id', d['failure_modes'][0]['id']))
w("unobservable", lambda d: d['signals'][0]['telemetry'].__setitem__('exists', False))
w("nosource",     lambda d: d['failure_modes'][0].pop('source_refs'))
w("nocoverage",   lambda d: d['coverage'].pop())
w("badenum",      lambda d: d['signals'][0].__setitem__('detection_class', 'vibes'))
PY
for n in dangling dupe unobservable nosource nocoverage badenum; do
  python3 "$SKILL/scripts/ledger.py" --validate "$TMP/$n.yaml" >/dev/null 2>&1
  if [ $? -ne 0 ]; then ok "rejects: $n"; else bad "accepted invalid ledger: $n"; fi
done

echo "== id stability =="
python3 - "$FIX/ledger-v1.yaml" "$TMP" <<'PY'
import yaml, sys
led = yaml.safe_load(open(sys.argv[1])); out = sys.argv[2]
for sec in ('assets', 'failure_modes', 'log_sources'):
    for e in led[sec]:
        e.pop('id', None)
for name in ('ida', 'idb'):
    yaml.safe_dump(led, open(f"{out}/{name}.yaml", "w"), sort_keys=False)
PY
python3 "$SKILL/scripts/ledger.py" --assign-ids --write "$TMP/ida.yaml" >/dev/null 2>&1
python3 "$SKILL/scripts/ledger.py" --assign-ids --write "$TMP/idb.yaml" >/dev/null 2>&1
diff -q "$TMP/ida.yaml" "$TMP/idb.yaml" >/dev/null 2>&1
check $? "two --assign-ids runs are byte-identical"

echo "== delta report =="
python3 "$SKILL/scripts/diff_ledger.py" "$FIX/ledger-v1.yaml" "$FIX/ledger-v1.yaml" 2>/dev/null | grep -q "^No change since"
check $? "self-diff is quiet (a re-run over an unchanged target must produce no noise)"

python3 - "$SKILL" "$FIX" <<'PY'
import subprocess, json, sys
skill, fix = sys.argv[1], sys.argv[2]
d = json.loads(subprocess.run([sys.executable, f"{skill}/scripts/diff_ledger.py",
                               f"{fix}/ledger-v1.yaml", f"{fix}/ledger-v2.yaml",
                               "--format", "json"], capture_output=True, text=True).stdout)
expect = {"new": 2, "resolved": 1, "drifted": 1, "stale": 1}
bad = {k: (len(d[k]), v) for k, v in expect.items() if len(d[k]) != v}
if bad: sys.exit(f"delta miscounted (got, expected): {bad}")
ids = {r["id"] for r in d["stale"]}
assert ids & {"FM-creds-in-logs-1234"}, "stale entry not identified"
assert not (ids & {r["id"] for r in d["drifted"]}), "stale entry double-reported as drifted"
print("delta: 2 new / 1 resolved / 1 drifted / 1 stale, no double-reporting")
PY
check $? "delta classifies new, resolved, drifted and stale correctly"

echo "== output adapter templates =="
python3 - "$SKILL" <<'PY'
"""The Panther template must be a rule that actually runs and passes its own fixtures."""
import re, yaml, types, sys, pathlib
skill = sys.argv[1]
doc = pathlib.Path(f"{skill}/references/outputs/panther.md").read_text()
code = re.search(r"```python\n(.*?)```", doc, re.S).group(1)
meta = yaml.safe_load(re.findall(r"```yaml\n(.*?)```", doc, re.S)[0])

class Event(dict):
    def deep_get(self, *keys, default=None):
        cur = self
        for k in keys:
            if not isinstance(cur, dict) or k not in cur:
                return default
            cur = cur[k]
        return cur

mod = types.ModuleType("generated_rule")
exec(compile(code, "panther.md", "exec"), mod.__dict__)
for t in meta["Tests"]:
    got = mod.rule(Event(t["Log"]))
    if got != t["ExpectedResult"]:
        sys.exit(f"fixture {t['Name']!r}: expected {t['ExpectedResult']}, got {got}")
assert {"true", "false"} <= {str(t["ExpectedResult"]).lower() for t in meta["Tests"]}, \
    "template must ship both a positive and a negative fixture"
assert meta["Severity"] in ("Critical", "High", "Medium", "Low", "Info")
ev = Event(meta["Tests"][0]["Log"])
assert mod.dedup(ev) and mod.title(ev) and mod.alert_context(ev)
print("panther template: rule runs, both fixtures pass, metadata valid")
PY
check $? "panther template executes and passes its own fixtures"

python3 - "$SKILL" <<'PY'
"""The CloudWatch template must have the settings that absence detection depends on."""
import re, sys, pathlib
skill = sys.argv[1]
hcl = re.search(r"```hcl\n(.*?)```",
                pathlib.Path(f"{skill}/references/outputs/cloudwatch.md").read_text(), re.S).group(1)
required = {
    'default_value = "0"': 'without it the metric emits nothing rather than zeros',
    'treat_missing_data = "breaching"': 'without it the alarm never fires when logs stop',
}
for needle, why in required.items():
    if needle not in hcl:
        sys.exit(f"absence-detection template missing {needle} - {why}")
assert hcl.count("{") == hcl.count("}"), "unbalanced braces"
try:
    import hcl2, io
    hcl2.load(io.StringIO(hcl))
    print("cloudwatch template: parses as HCL, absence settings present")
except ImportError:
    print("cloudwatch template: absence settings present (hcl2 not installed, parse skipped)")
PY
check $? "cloudwatch template is valid and gets absence detection right"

python3 - "$SKILL" <<'PY'
import re, yaml, sys, pathlib
skill = sys.argv[1]
doc = pathlib.Path(f"{skill}/references/outputs/wiz.md").read_text()
ctl = yaml.safe_load(re.search(r"```yaml\n(.*?)```", doc, re.S).group(1))
for k in ("id", "name", "description", "severity", "target", "expected", "remediation"):
    assert k in ctl, f"wiz template missing {k}"
print("wiz template: parses, all required sections present")
PY
check $? "wiz template parses and is structurally complete"

echo
echo "=============================="
echo " $pass passed, $fail failed"
echo "=============================="
[ "$fail" -eq 0 ]
