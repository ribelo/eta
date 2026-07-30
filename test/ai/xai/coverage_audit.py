#!/usr/bin/env python3
"""Bidirectional eta-ai-xai requirement/test-reference audit.

Successful output is a machine-readable JSON coverage report.  References are
accepted only from executable xAI tests/checks, or from the exact external
named-test registry in external_coverage.tsv.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = (
    pathlib.Path(sys.argv[1]).resolve()
    if len(sys.argv) > 1
    else pathlib.Path(__file__).resolve().parents[3]
)
REQ_DIR = ROOT / "docs/requirements/eta-ai-xai"
TEST_DIRS = (ROOT / "test/ai/xai", ROOT / "test/ai/xai_eio")
EXTERNAL = ROOT / "test/ai/xai/external_coverage.tsv"
ID = re.compile(r"(?<![a-z0-9-])((?:xai|airealtime)[a-z0-9]*-[a-z0-9]{4})(?![a-z0-9-])")
SOURCE_SUFFIXES = {".ml", ".sh"}


def requirement_ids() -> dict[str, str]:
    found: dict[str, str] = {}
    for path in sorted(REQ_DIR.glob("*.md")):
        for line in path.read_text().splitlines():
            match = re.search(r"\^((?:xai|airealtime)[a-z0-9]*-[a-z0-9]{4})$", line)
            if match:
                rid = match.group(1)
                if rid in found:
                    raise SystemExit(f"duplicate requirement ID: {rid}")
                found[rid] = str(path.relative_to(ROOT))
    return found


def local_references() -> dict[str, list[str]]:
    refs: dict[str, list[str]] = {}
    for directory in TEST_DIRS:
        for path in sorted(directory.rglob("*")):
            if path.suffix not in SOURCE_SUFFIXES or path.name == pathlib.Path(__file__).name:
                continue
            relative = str(path.relative_to(ROOT))
            for number, line in enumerate(path.read_text().splitlines(), 1):
                for rid in ID.findall(line):
                    refs.setdefault(rid, []).append(f"{relative}:{number}")
    return refs


def external_references() -> dict[str, list[str]]:
    refs: dict[str, list[str]] = {}
    for number, line in enumerate(EXTERNAL.read_text().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        rid, relative, case = line.split("\t")
        path = ROOT / relative
        text = path.read_text()
        if rid not in text:
            raise SystemExit(f"{EXTERNAL}:{number}: {rid} is absent from {relative}")
        registration = f'Alcotest.test_case "{case}"'
        if registration not in text:
            raise SystemExit(
                f"{EXTERNAL}:{number}: named test registration {case!r} is absent from {relative}"
            )
        refs.setdefault(rid, []).append(f"{relative}::{case}")
    return refs


def main() -> int:
    requirements = requirement_ids()
    references = local_references()
    for rid, locations in external_references().items():
        references.setdefault(rid, []).extend(locations)
    missing = sorted(set(requirements) - set(references))
    stale = sorted(set(references) - set(requirements))
    report = {
        "requirements": len(requirements),
        "covered": len(set(requirements) & set(references)),
        "missing": missing,
        "stale": stale,
        "references": {rid: references[rid] for rid in sorted(references)},
    }
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 1 if missing or stale else 0


if __name__ == "__main__":
    sys.exit(main())
