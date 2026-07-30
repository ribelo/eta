---
kind: requirement
---
# Eta AI provider errors

## Intent

Preserve failure facts published by first-class providers without forcing every
provider to expose a nominal wrapper around the same shared error value.

## Requirements

- Where a first-class provider failure contract contains facts that `Eta_ai.ai_error` cannot represent losslessly, the provider package shall expose a nominal provider-specific error type. ^aierr-kmfl
- When a nominal provider error represents an HTTP provider failure, the provider error shall preserve the HTTP status, response headers, structured provider payload when decodable, and raw response body. ^aierr-20g2
- When a provider package exposes a nominal provider error, the provider package shall expose an explicit projection from that error to `Eta_ai.ai_error`. ^aierr-1ew7
- The `eta_ai_openai` package shall expose a lossless nominal OpenAI error type and an explicit projection to `Eta_ai.ai_error`. ^aierr-gyer

## Open questions

- Which provider-specific facts, if any, require nominal errors for Anthropic,
  OpenRouter, Kimi Coding, Moonshot, and OpenAI Codex?
- Should the dynamic `eta_ai_openai_compat` adapter remain on
  `Eta_ai.ai_error`, or expose a lossless compatibility-envelope error?
- Which local validation and codec failures belong directly in each nominal
  error rather than in a shared nested failure case?
