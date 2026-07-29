# ADR 0006: Separate Polymorphic Responses Requests

Status: accepted.

## Context

Eta AI originally used `chat_request` for both Chat Completions and Responses.
xAI and current OpenAI Responses expose lifecycle and tool concepts that do not
belong to Chat Completions: stored-response chaining, input items, compaction,
provider-executed tools, service tiers, and lossless output-item replay.

Provider tool sets also differ. A single closed common tool sum would either
exclude provider features or admit invalid provider/tool combinations.

## Decision

Eta AI exposes a distinct `'tool Eta_ai.Responses.request`. The request owns
provider-neutral Responses fields and parameterizes the provider-specific tool
type. Chat Completions continues to use its own request type.

Provider packages own their complete tool and output-item algebras. They may
project lossless provider responses and stream events explicitly into the
provider-neutral Eta AI response vocabulary.

The OpenAI provider migrates to the new Responses request directly. Eta does not
retain the previous combined request as a compatibility path.

## Rejected

- Adding all Responses fields to `chat_request`. This obscures which endpoint
  accepts each field.
- Encoding provider tools as raw JSON. This loses discoverability and local
  validation.
- One global union of every provider tool. This admits combinations rejected by
  individual providers.
- Provider-local duplicate request records. The Responses lifecycle fields are
  genuinely shared.

## Consequences

- OpenAI and xAI share one Responses request lifecycle without sharing tool
  algebras.
- Existing OpenAI Responses callers must migrate to the new request type.
- Provider codecs remain responsible for rejecting unsupported fields rather
  than silently dropping them.

## Evidence

- `docs/requirements/eta-ai-xai/responses.md`
- `.scratch/research/xai/voice-apis-first-party-2026-07-29.md`
- `lib/ai/openai_codec/responses.ml`
