#!/usr/bin/env bash
set -euo pipefail

root=${1:-$(cd "$(dirname "$0")/../../.." && pwd)}
cd "$root"

pass() {
  local id=$1
  shift
  if ! "$@"; then
    printf 'requirement %s failed: %q' "$id" "$1" >&2
    printf ' %q' "${@:2}" >&2
    printf '\n' >&2
    exit 1
  fi
}

has() { grep -Eq "$1" "$2"; }
lacks() { ! grep -Eq "$1" "$2"; }
ephemeral_lacks_call_id() {
  ! sed -n '/^val connect_ephemeral :/,/^(t, error) Eta.Effect.t/p' "$1" |
    grep -q 'call_id'
}

# Each check below is the executable assertion for the adjacent requirement ID.
pass xaipkg-ksx3 has '\(name eta_ai_xai\)' dune-project
pass xaipkg-s6f5 has '\(public_name eta_ai_xai\)' lib/ai/xai/dune
pass xaipkg-rklu test -f lib/ai/xai/eta_ai_xai.mli
pass xaipkg-jzib has '\(name eta_ai_xai_eio\)' dune-project
pass xaipkg-2l5t has '\(public_name eta_ai_xai_eio\)' lib/ai/xai_eio/dune
pass xaipkg-dqp6 test -f lib/ai/xai_eio/eta_ai_xai_eio.mli
pass xaipkg-l05k lacks 'eta_ai_xai' eta.opam
pass xaipkg-3ux0 has 'module (Responses|Files|Collections|Models|Speech_to_text|Text_to_speech|Voices|Realtime)' lib/ai/xai/eta_ai_xai.mli
pass xaipkg-8ps8 lacks '(^|[[:space:]])(eio|eta_http_eio)([[:space:]]|$)' lib/ai/xai/dune
pass xaipkg-zt8a has '^module Responses_ws = Responses_ws$' lib/ai/xai_eio/eta_ai_xai_eio.mli
pass xaipkg-6h9t has '^module Realtime = Realtime$' lib/ai/xai_eio/eta_ai_xai_eio.mli
pass xaipkg-zj7x has '^module Streaming_stt = Streaming_stt$' lib/ai/xai_eio/eta_ai_xai_eio.mli
pass xaipkg-79yf has '^module Streaming_tts = Streaming_tts$' lib/ai/xai_eio/eta_ai_xai_eio.mli
pass xaipkg-jm8z lacks 'eta_ai_(openai|anthropic|openrouter|moonshot|kimi)' lib/ai/xai/dune

pass xaisurf-errd has 'module (Responses|Files|Collections|Models|Speech_to_text|Text_to_speech|Voices|Realtime)' lib/ai/xai/eta_ai_xai.mli
pass xaipkg-rhsy lacks 'Live_translation|live_translation[[:space:]]*:' lib/ai/xai/eta_ai_xai.mli
pass xaipkg-tzj8 lacks '^(val|type|module).*(Phone|phone|Call_control|call_control)' lib/ai/xai/eta_ai_xai.mli
pass xaivoice-6b5p lacks '^val (create|update|delete|clone)_custom' lib/ai/xai/voices.mli

# Nominal/private signatures are compile-time security assertions.
pass xaicol-tz3p has '^type management_key = private string Eta_redacted.t$' lib/ai/xai/collections.mli
pass xaisec-tlxw has '^type client_secret = private string Eta_redacted.t$' lib/ai/xai/realtime.mli

# The shared protocol seams are distinct public modules, not aliases.
pass airealtime-5xcr lacks 'type (session|server_event) = Eta_ai_openai' lib/ai/xai/realtime.mli
pass airealtime-xem8 has 'with type session = session' lib/ai/xai/realtime.mli
pass airealtime-6gv2 has 'Binary of bytes' lib/ai/eta_ai.mli
pass airealtime-u580 has '^module Streaming_stt = Streaming_stt$' lib/ai/xai_eio/eta_ai_xai_eio.mli
pass airealtime-zwge has '^module Streaming_tts = Streaming_tts$' lib/ai/xai_eio/eta_ai_xai_eio.mli
pass airealtime-32fe has '^module Responses_ws = Responses_ws$' lib/ai/xai_eio/eta_ai_xai_eio.mli
pass xaistt-afb9 has '^module Streaming_stt = Streaming_stt$' lib/ai/xai_eio/eta_ai_xai_eio.mli
pass xaistt-7mqs lacks 'type event = Streaming_tts.event' lib/ai/xai_eio/streaming_stt.mli
pass xaitts-f5w0 has '^module Streaming_tts = Streaming_tts$' lib/ai/xai_eio/eta_ai_xai_eio.mli
pass xaitts-1cyg lacks 'type event = Streaming_stt.event' lib/ai/xai_eio/streaming_tts.mli
pass xairsp-k16t lacks 'type t = Realtime.t' lib/ai/xai_eio/responses_ws.mli
pass xairt-7t3a ephemeral_lacks_call_id lib/ai/xai_eio/realtime.mli
pass xairt-tuno lacks 'type tool = Responses.tool' lib/ai/xai/realtime.mli
pass xairt-s34d has '^type t = {$' lib/ai/xai_eio/realtime.ml
pass xairsp-pth1 has '^type stream_event =$' lib/ai/xai/responses.mli
pass xaistt-bbo1 has 'Bytes.length file.A.data > 500_000_000' lib/ai/xai/speech_to_text.ml
