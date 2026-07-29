# ADR 0008: xAI Provider Boundary

Status: accepted.

## Context

xAI exposes OpenAI-compatible Responses alongside provider-specific Responses
tools, resource APIs, and four distinct voice transports. Its collection
management API uses a separate authority and credential. Live Translation has
no public callable contract, and custom-voice creation is enterprise-gated.

The Eta package policy requires optional providers and runtime adapters to carry
their own dependencies.

## Decision

`eta_ai_xai` is the transport-neutral provider package for Responses, Files,
Collections, Models, unary speech-to-text, unary text-to-speech, voice discovery,
Realtime codecs, and all other xAI protocol codecs in the approved requirement
set.

`eta_ai_xai_eio` supplies the Eio adapters for Responses WebSocket, Realtime
speech, streaming speech-to-text, and streaming text-to-speech.

xAI-specific responses, events, errors, tools, and resources remain lossless
typed values with explicit projections to Eta AI common values. Inference,
management, and ephemeral credentials are distinct redacted types.

Custom-voice operations are read-only: list, get, reference-audio download, and
use by opaque ID. The provider does not speculate about Live Translation and
does not include phone-number or call-control management.

## Rejected

- Treating xAI only as `eta_ai_openai_compat`. That omits provider tools,
  resources, voice protocols, and lossless output items.
- Putting Eio in `eta_ai_xai`. This would force a runtime adapter on REST-only
  users.
- Speculative Live Translation types. No callable contract exists.
- Automatic tool or shell execution. Applications own execution policy and
  state.

## Consequences

- Applications install only the xAI surfaces and transports they use.
- xAI's two credential authorities cannot be mixed accidentally.
- Future browser transports can reuse the transport-neutral codecs without
  changing the provider package.

## Evidence

- `docs/requirements/eta-ai-xai/`
- `.scratch/research/xai/voice-apis-first-party-2026-07-29.md`
