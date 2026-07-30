---
kind: requirement
---
# Cross-provider audio vocabulary

## Intent

Share only genuine OpenAI/xAI audio concepts while preserving each provider's
lossless requests, responses, errors, sessions, and events.

## Requirements

- Eta AI shall expose `Audio` as the module owning provider-neutral audio request and result subsets. ^oabridge-a730
- The provider-neutral audio subsets shall represent only vocabulary shared by the OpenAI and xAI audio contracts. ^oabridge-ctoh
- Each first-class audio provider shall expose conversion from the provider-neutral audio request subset into its own request construction. ^oabridge-pmod
- When a caller converts a provider-neutral audio request, the provider shall require its provider-specific configuration before yielding a submittable request. ^oabridge-d348
- Each first-class audio provider shall expose explicit projection from its provider audio result into the provider-neutral audio result subset. ^oabridge-ff14
- The OpenAI and xAI providers shall each expose `Audio.Speech_to_text`, `Audio.Text_to_speech`, `Audio.Voices`, and `Audio.Realtime` modules. ^oabridge-0eee
- The xAI provider shall obtain provider-neutral audio vocabulary from Eta AI rather than defining equivalent local vocabulary. ^oabridge-i191
- Each audio provider module shall expose its audio types directly rather than requiring functor instantiation. ^oabridge-6pj8
- Eta AI shall express shared audio lifecycle contracts as module types that each provider includes with its own types. ^oabridge-hzv9
- The OpenAI and xAI audio providers shall retain separate full-fidelity provider request, response, event, and error types. ^oabridge-w4yk
- The OpenAI and xAI audio providers shall not expose direct pairwise dependencies on one another's public types. ^oabridge-zo0u
- Where OpenAI and xAI implement the same lifecycle invariant, Eta AI shall expose a provider-neutral interface parameterized by each provider's own types. ^oabridge-1h2i
- When a provider-specific audio value is projected into common Eta AI vocabulary, the projection shall be explicit. ^oabridge-x4ig
