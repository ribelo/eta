---
kind: requirement
---
# xAI package boundary

## Intent

Keep xAI support independently installable and isolate Eio-specific WebSocket
transport from the transport-neutral provider library.

## Requirements

- The xAI provider shall be distributed in the opam package `eta_ai_xai`. ^xaipkg-ksx3
- The opam package `eta_ai_xai` shall install the Dune public library `eta_ai_xai`. ^xaipkg-s6f5
- The Dune public library `eta_ai_xai` shall export the OCaml module `Eta_ai_xai`. ^xaipkg-rklu
- The xAI Eio transport shall be distributed in the opam package `eta_ai_xai_eio`. ^xaipkg-jzib
- The opam package `eta_ai_xai_eio` shall install the Dune public library `eta_ai_xai_eio`. ^xaipkg-2l5t
- The Dune public library `eta_ai_xai_eio` shall export the OCaml module `Eta_ai_xai_eio`. ^xaipkg-dqp6
- The root opam package `eta` shall remain installable without `eta_ai_xai` or `eta_ai_xai_eio`. ^xaipkg-l05k
- The Dune public library `eta_ai_xai` shall expose transport-neutral xAI types, codecs, HTTP request construction, and REST runners. ^xaipkg-3ux0
- The Dune public library `eta_ai_xai` shall remain independent of Eio and `eta_http_eio`. ^xaipkg-8ps8
- The Dune public library `eta_ai_xai_eio` shall provide the xAI Responses WebSocket transport. ^xaipkg-zt8a
- The Dune public library `eta_ai_xai_eio` shall provide the xAI Realtime speech WebSocket transport. ^xaipkg-6h9t
- The Dune public library `eta_ai_xai_eio` shall provide the xAI streaming speech-to-text WebSocket transport. ^xaipkg-zj7x
- The Dune public library `eta_ai_xai_eio` shall provide the xAI streaming text-to-speech WebSocket transport. ^xaipkg-79yf
- The xAI provider shall implement xAI-specific behavior without depending on another provider package. ^xaipkg-jm8z
