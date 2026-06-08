import json
import sys


payload = json.load(sys.stdin)
diagnostics = payload.get("value", [])
errors = [
    item
    for item in diagnostics
    if item.get("type") != "config"
    or not item.get("message", "").startswith("No config found for file")
]

if errors:
    print(json.dumps(errors, indent=2), file=sys.stderr)
    raise SystemExit(1)

print("merlin diagnostics: []")
