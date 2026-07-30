#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../../.." && pwd)"
eta_dune="$root/lib/eta/dune"
backup="$(mktemp)"
cp "$eta_dune" "$backup"
restore() {
  cp "$backup" "$eta_dune"
  rm -f "$backup"
}
trap restore EXIT

python3 - "$eta_dune" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
needle = "  runtime_trace_context\n  runtime_supervisor))"
replacement = "  runtime_trace_context\n  runtime_supervisor)\n (libraries eta_observability))"
if needle not in text:
    raise SystemExit("unexpected lib/eta/dune shape")
path.write_text(text.replace(needle, replacement))
PY

cd "$root"
if nix develop -c dune build lib/eta/eta.cmxa; then
  echo "FAIL dune accepted eta <-> eta_observability cycle" >&2
  exit 1
fi

echo "PASS dune rejected eta <-> eta_observability cycle"
