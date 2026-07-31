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
    root / "lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml",
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
for sibling in ["Conversation", "Transcription", "Translation"]:
    if realtime.count(f"module {sibling} : sig") != 1:
        errors.append(f"lib/ai/openai/realtime.mli: missing unique {sibling} sibling")
for forbidden in [
    "Raw_client_event",
    "Raw_server_event",
    "type session = Conversation.session",
    "type client_event = Conversation.client_event",
    "type server_event = Conversation.server_event",
]:
    if forbidden in realtime:
        errors.append(f"lib/ai/openai/realtime.mli: forbidden compatibility surface {forbidden}")
decoder = r"val decode_server_event : Eta_ai\.raw_json -> \(server_event, codec_error\) result"
if len(re.findall(decoder, realtime)) != 3:
    errors.append("lib/ai/openai/realtime.mli: all three raw decoders must use their nominal codec_error")

eio = texts[root / "lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.mli"]
for sibling in ["Conversation", "Transcription", "Translation"]:
    if eio.count(f"module {sibling} : sig") != 1:
        errors.append(f"lib/ai/openai_realtime_eio.mli: missing unique {sibling} connection module")
if len(re.findall(r"\btype t\b", eio)) != 3:
    errors.append("lib/ai/openai_realtime_eio.mli: connection types are not three distinct abstracts")
error_shape = r"type error = \| Websocket of Eta_http_eio\.Ws\.Client\.ws_error \| Openai_error of Eta_ai_openai\.Error\.t \| Concurrent_read \| Already_finished \| Finished \| Aborted \| Timeout"
if len(re.findall(error_shape, eio)) != 3:
    errors.append("lib/ai/openai_realtime_eio.mli: all three transport errors must be distinct regular nominal types retaining OpenAI Error.t")
if "type error = [" in eio:
    errors.append("lib/ai/openai_realtime_eio.mli: structural polymorphic transport errors are forbidden")
for protocol in ["Conversation", "Transcription", "Translation"]:
    event = rf"Eta_ai_openai\.Audio\.Realtime\.{protocol}\.server_event"
    for signature in [
        rf"val read_event : t -> \({event} option, error\) Eta\.Effect\.t",
        rf"val events : t -> \({event}, error\) Eta_stream\.Stream\.t",
    ]:
        if not re.search(signature, eio):
            errors.append(f"lib/ai/openai_realtime_eio.mli: missing nominal signature matching {signature}")

eio_impl = texts[root / "lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml"]
if 'let path = "/v1/realtime/translations"' not in eio_impl:
    errors.append("lib/ai/openai_realtime_eio.ml: translation endpoint path is not dedicated")
if 'path ^ "?model=" ^ percent_encode model' not in eio_impl:
    errors.append("lib/ai/openai_realtime_eio.ml: realtime model is not selected in the WebSocket query")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
