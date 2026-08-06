#!/usr/bin/env python3
"""Check that ignored generated tests exactly match their recorded sources."""

import json
import subprocess
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
manifest_path = here / "generated/source-manifest.json"
if not manifest_path.exists():
    sys.exit("generated/source-manifest.json is missing; run ./generate.py")

before = manifest_path.read_bytes()
files_before = {
    entry["generated"]: (here / entry["generated"]).read_bytes()
    for entry in json.loads(before)
}
subprocess.run([sys.executable, str(here / "generate.py")], check=True)
after = manifest_path.read_bytes()
files_after = {
    entry["generated"]: (here / entry["generated"]).read_bytes()
    for entry in json.loads(after)
}
if before != after or files_before != files_after:
    sys.exit("generated tests or source hashes were stale")
print("generated tests and source hashes: pass")
