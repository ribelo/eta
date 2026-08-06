#!/usr/bin/env python3
"""Generate finalist-bound copies of the frozen public Signal tests."""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
OUT = HERE / "generated"
HASHES = HERE / "source-hashes.json"

FILES = {
    "test/signal/eta_signal_test_helpers.ml": "eta_signal_test_helpers.ml",
    "test/signal/eta_signal_test_interrupt_runtime.ml": "eta_signal_test_interrupt_runtime.ml",
    "test/signal/test_eta_signal.ml": "test_eta_signal.ml",
    "test/signal/test_eta_signal_public.ml": "test_eta_signal_public.ml",
    "test/signal/contract/test_eta_signal_contract.ml": "test_eta_signal_contract.ml",
    "test/signal/model/test_eta_signal_model.ml": "test_eta_signal_model.ml",
    "test/signal_stream/test_eta_signal_stream.ml": "test_eta_signal_stream.ml",
    "test/signal_map/test_eta_signal_map.ml": "test_eta_signal_map.ml",
    "test/signal_map/keyed/test_eta_signal_map_keyed.ml": "test_eta_signal_map_keyed.ml",
    "test/laws/signal_properties.ml": "signal_properties.ml",
}

NEGATIVE_DIRS = ("test/signal/negative", "test/signal_map/negative")
FACTORY_TOKEN = re.compile(r"\bEta_signal\.(?:Make|Make_no_error)\b")
MAKE = re.compile(r"Eta_signal\.Make\s*\(([^()\n]+)\)\s*\(\)")
MAKE_NO_ERROR = re.compile(r"Eta_signal\.Make_no_error\s*\(\)")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def substitute(source: str, path: str) -> tuple[str, int]:
    expected = len(FACTORY_TOKEN.findall(source))
    transformed, no_error_count = MAKE_NO_ERROR.subn(
        "Selected_factory_fresh.Make (Eta_signal.No_observer_error) ()", source
    )
    transformed, make_count = MAKE.subn(
        r"Selected_factory_fresh.Make (\1) ()", transformed
    )
    actual = no_error_count + make_count
    if actual != expected or FACTORY_TOKEN.search(transformed):
        raise SystemExit(
            f"{path}: unexpected factory expression "
            f"(found {expected}, safely replaced {actual})"
        )
    return transformed, actual


def write_copy(source_name: str, target: Path, manifest: list[dict[str, object]]) -> None:
    source_path = REPO / source_name
    raw = source_path.read_bytes()
    transformed, replacements = substitute(raw.decode(), source_name)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(transformed)
    manifest.append(
        {
            "source": source_name,
            "source_sha256": digest(raw),
            "generated": str(target.relative_to(HERE)),
            "generated_sha256": digest(transformed.encode()),
            "factory_replacements": replacements,
        }
    )


def main() -> None:
    if OUT.exists():
        shutil.rmtree(OUT)
    manifest: list[dict[str, object]] = []
    for source, target in FILES.items():
        # Dune modules live beside the tracked dune file; generated sources remain
        # ignored and are reproducible from this manifest.
        write_copy(source, HERE / target, manifest)
    for directory in NEGATIVE_DIRS:
        target_dir = OUT / ("negative-map" if "signal_map" in directory else "negative-signal")
        for source_path in sorted((REPO / directory).glob("*.ml")):
            write_copy(
                str(source_path.relative_to(REPO)), target_dir / source_path.name, manifest
            )
    manifest_path = OUT / "source-manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    source_hashes = {
        entry["source"]: entry["source_sha256"] for entry in manifest
    }
    if "--record-hashes" in sys.argv[1:]:
        HASHES.write_text(json.dumps(source_hashes, indent=2, sort_keys=True) + "\n")
    elif not HASHES.exists():
        raise SystemExit("source-hashes.json is missing; initialize with --record-hashes")
    else:
        recorded = json.loads(HASHES.read_text())
        if recorded != source_hashes:
            changed = sorted(set(recorded) | set(source_hashes))
            changed = [
                path for path in changed if recorded.get(path) != source_hashes.get(path)
            ]
            raise SystemExit("source hash drift: " + ", ".join(changed))
    print(f"generated {len(manifest)} files; manifest: {manifest_path}")


if __name__ == "__main__":
    main()
