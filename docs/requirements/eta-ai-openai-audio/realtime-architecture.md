---
kind: requirement
---
# OpenAI Realtime audio architecture

## Intent

Expose each OpenAI Realtime audio state machine explicitly while sharing only
private WebSocket mechanics and the provider-neutral lifecycle shape.

## Requirements

- The OpenAI Realtime module shall expose `Conversation`, `Transcription`, and `Translation` as explicit sibling protocol modules. ^oartc-tr2e
- The OpenAI provider shall move the existing conversational Realtime public surface under `Realtime.Conversation`. ^oartc-ik5k
- The OpenAI provider shall not retain the previous conversational Realtime path as a compatibility alias. ^oartc-6bop
- Each OpenAI Realtime protocol shall own separate full-fidelity session, client-event, server-event, codec-error, and nominal transport-error types. ^oartc-2o0l
- The OpenAI Eio transport shall expose distinct abstract Conversation, Transcription, and Translation connection types. ^oartc-co6h
- The OpenAI Eio transport shall share WebSocket framing, scoped ownership, serialized sending, event pulling, cancellation, and release through private machinery. ^oartc-iqo5
- The OpenAI Realtime public surface shall prevent a client event for one protocol from being sent through another protocol's connection. ^oartc-bvjo
- When OpenAI emits a documented audio-related Realtime event, the owning protocol shall decode it into a typed provider event preserving complete raw JSON. ^oartc-1ku4
- If OpenAI emits an undocumented Realtime event type, then the owning protocol shall preserve its type and complete JSON in an `Unknown` event. ^oartc-fjda
- The OpenAI Realtime audio expansion shall include audio-related client-secret, WebSocket, WebRTC call-setup, call-control, and SIP lifecycle contracts. ^oartc-bfmv
- The OpenAI Realtime audio expansion shall not broaden unrelated MCP behavior. ^oartc-84ls
- The shared Eta AI Realtime interface shall retain provider-specific OpenAI and xAI protocol algebras behind a common lifecycle shape. ^oartc-nezv

## Open questions

- How exhaustive shall local Realtime state validation be?
- Which framing and pending-event bounds shall be configurable?
- Should common Conversation, Transcription, and Translation module signatures be added to `Eta_ai.Realtime`?
