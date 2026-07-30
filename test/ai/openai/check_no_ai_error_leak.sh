#!/usr/bin/env bash
# Exact public API census for aierr-le4v.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
python3 - "$root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
files = [
    root / "lib/ai/eta_ai.mli",
    root / "lib/ai/openai/eta_ai_openai.mli",
    root / "lib/ai/openai/openai_error.mli",
    root / "lib/ai/openai/realtime.mli",
    root / "lib/ai/openai_compat/eta_ai_openai_compat.mli",
    root / "lib/ai/openai_compat/compat_error.mli",
    root / "lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.mli",
]

def strip_ocaml_comments(text: str) -> str:
    out = []
    depth = 0
    i = 0
    in_string = False
    escaped = False
    while i < len(text):
        pair = text[i:i + 2]
        ch = text[i]
        if depth:
            if pair == "(*":
                depth += 1
                i += 2
            elif pair == "*)":
                depth -= 1
                i += 2
            else:
                if ch == "\n":
                    out.append("\n")
                i += 1
        elif in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
        elif pair == "(*":
            depth = 1
            i += 2
        else:
            out.append(ch)
            if ch == '"':
                in_string = True
            i += 1
    if depth:
        raise SystemExit("unterminated OCaml comment")
    return "".join(out)

def normalized(path: Path) -> str:
    return re.sub(r"\s+", " ", strip_ocaml_comments(path.read_text()))

texts = {path: normalized(path) for path in files}
errors = []

# Only the two explicit neutral projection functions may mention ai_error in
# provider-specific error interfaces. Provider-value constructors return the
# abstract Eta_ai.provider type and therefore need no textual exception.
allowed = {
    root / "lib/ai/openai/openai_error.mli": [
        "val of_ai_error : Eta_ai.ai_error -> t",
        "val to_ai_error : t -> Eta_ai.ai_error",
    ],
    root / "lib/ai/openai_compat/compat_error.mli": [
        "val of_ai_error : ?provider:Eta_ai.provider_name -> Eta_ai.ai_error -> t",
        "val to_ai_error : t -> Eta_ai.ai_error",
    ],
}
for path, text in texts.items():
    checked = text
    for signature in allowed.get(path, []):
        if checked.count(signature) != 1:
            errors.append(f"{path.relative_to(root)}: missing exact allowlisted signature: {signature}")
        checked = checked.replace(signature, "", 1)
    if path != root / "lib/ai/eta_ai.mli" and re.search(r"\b(?:Eta_ai\.)?ai_error\b", checked):
        errors.append(f"{path.relative_to(root)}: forbidden ai_error token outside exact projections")
    if re.search(r"\bServer_decode_error\b", checked):
        errors.append(f"{path.relative_to(root)}: forbidden successful Server_decode_error route")

for path in [root / "lib/ai/openai/eta_ai_openai.mli", root / "lib/ai/openai_compat/eta_ai_openai_compat.mli"]:
    text = texts[path]
    if re.search(r"\bEta_ai\.stream\b", text):
        errors.append(f"{path.relative_to(root)}: nominal stream surface leaks Eta_ai.stream")
    if "type stream" not in text:
        errors.append(f"{path.relative_to(root)}: missing provider-owned stream type")

eta_text = texts[root / "lib/ai/eta_ai.mli"]
if re.search(r"\bval stream_provider\b", eta_text):
    errors.append("lib/ai/eta_ai.mli: forbidden top-level stream_provider")

realtime = texts[root / "lib/ai/openai/realtime.mli"]
if not re.search(r"val decode_server_event : Eta_ai\.raw_json -> \(server_event, error\) result", realtime):
    errors.append("lib/ai/openai/realtime.mli: raw decoder is not nominal")

eio = texts[root / "lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.mli"]
if not re.search(r"type realtime_error = \[ Eta_http_eio\.Ws\.Client\.ws_error \| `Openai_error of Eta_ai_openai\.Error\.t \]", eio):
    errors.append("lib/ai/openai_realtime_eio.mli: realtime_error does not structurally retain OpenAI Error.t")
for signature in [
    r"val read_event : t -> \(Eta_ai_openai\.Realtime\.server_event option, realtime_error\) Eta\.Effect\.t",
    r"val events : t -> \(Eta_ai_openai\.Realtime\.server_event, realtime_error\) Eta_stream\.Stream\.t",
]:
    if not re.search(signature, eio):
        errors.append(f"lib/ai/openai_realtime_eio.mli: missing nominal signature matching {signature}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
