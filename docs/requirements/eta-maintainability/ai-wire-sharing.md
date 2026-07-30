---
kind: requirement
---
# Eta AI wire sharing

## Intent

Centralize wire behavior only where several provider adapters implement the
same contract, while preserving provider-specific protocols and error domains.

## Requirements

- The `eta_ai_openai_codec` package shall own the shared normalization of Responses reasoning effort used by OpenAI-wire providers. ^aiwire-gixc
- When OpenAI or OpenRouter encodes a Responses request, the provider shall use the shared OpenAI-wire reasoning normalization. ^aiwire-g547
- The xAI provider shall expose one common operation that lifts request-construction results into JSON request execution and decoding. ^aiwire-izkg
- When xAI Files, Collections, or Responses executes a prebuilt JSON request result, the capability shall use the xAI common request-result operation. ^aiwire-4b5n
- The xAI provider shall expose common inference-endpoint GET construction and decoded execution for catalog-style resources. ^aiwire-agzf
- When xAI Models or Voices performs a catalog-style GET, the capability shall use the xAI common inference-endpoint operation. ^aiwire-3nch
- The Eta AI provider packages shall preserve provider-specific Realtime event, session, and error types. ^aiwire-0v35
- The Eta AI provider packages shall preserve provider-specific authentication and endpoint policy at the provider seam. ^aiwire-up1o
