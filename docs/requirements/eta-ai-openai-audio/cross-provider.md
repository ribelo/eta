---
kind: requirement
---
# Cross-provider audio vocabulary

## Intent

Share only genuine OpenAI/xAI audio concepts while preserving each provider's
lossless requests, responses, errors, sessions, and events.

## Requirements

- The OpenAI and xAI audio providers shall retain separate full-fidelity provider request, response, event, and error types. ^oabridge-w4yk
- The OpenAI and xAI audio providers shall not expose direct pairwise dependencies on one another's public types. ^oabridge-zo0u
- Where OpenAI and xAI implement the same lifecycle invariant, Eta AI shall expose a provider-neutral interface parameterized by each provider's own types. ^oabridge-1h2i
- When a provider-specific audio value is projected into common Eta AI vocabulary, the projection shall be explicit. ^oabridge-x4ig

## Open questions

- Should `Eta_ai.Audio` own minimal neutral request and result subsets with provider `of_eta_ai` and `to_eta_ai` projections, or only shared module signatures?
- Which common operations are meaningful when OpenAI and xAI impose incompatible required fields?
- Should the audio work migrate xAI simultaneously onto the resulting common vocabulary and lifecycle interfaces?
- Should both providers expose the same `Audio.Speech_to_text`, `Audio.Text_to_speech`, and `Audio.Realtime` module topology?
- If Eta AI owns a common request subset, how should provider-required fields be
  supplied without invalid optional-field records or silent defaults?
