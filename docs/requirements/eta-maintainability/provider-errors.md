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
- Every public `eta_ai_openai` constructor, codec, request builder, runner, and stream operation that can fail shall use `Eta_ai_openai.Error.t` as its error type. ^aierr-c4cn
- When an OpenAI HTTP failure contains an error payload, `Eta_ai_openai.Error.t` shall preserve its message, type, parameter, code, decoded JSON, status, headers, and raw body without coercing the parameter or code to strings. ^aierr-2b3g
- The `eta_ai_anthropic` package shall expose one nominal error type across its public fallible operations. ^aierr-ittf
- When an Anthropic HTTP failure contains an error payload, the Anthropic error type shall preserve the status, headers, top-level type, nested error type and message, request ID, decoded JSON, and raw body. ^aierr-7z5q
- The `eta_ai_openrouter` package shall expose one nominal error type across its public fallible operations. ^aierr-gi46
- When an OpenRouter HTTP failure contains an error payload, the OpenRouter error type shall preserve the status, headers, code, message, metadata, nested upstream response error, decoded JSON, and raw body. ^aierr-l7ol
- The `eta_ai_kimi_coding` package shall expose one nominal error type across inference, OAuth, device-authorization, credential, codec, request, and stream failures. ^aierr-3jcq
- The `eta_ai_moonshot` package shall expose its own nominal error type across its public fallible operations rather than exposing the Kimi Coding error type. ^aierr-ud5v
- The `eta_ai_openai_codex` package shall expose one nominal error type across inference, OAuth, callback, token, account, credential, codec, request, and stream failures. ^aierr-2r8e
- The `eta_ai_openai_compat` package shall expose a nominal compatibility-envelope error across its public fallible operations. ^aierr-yk92
- When the OpenAI-compatible adapter receives an HTTP failure, its nominal error shall preserve the configured provider name, status, headers, optional decoded payload, and raw body without requiring a provider-specific schema. ^aierr-iw3m
- When any nominal provider error represents local validation, unsupported input, codec failure, transport failure, or provider HTTP failure, it shall retain a distinct case sufficient to classify that failure without formatting its message. ^aierr-xe8o
- Each nominal provider error projection to `Eta_ai.ai_error` shall be total and shall discard provider-specific facts only at that explicit projection boundary. ^aierr-v0dd
- The `eta_ai_openai_codec` package shall decode OpenAI-compatible wire payloads without choosing the public nominal error type owned by a calling provider package. ^aierr-ytbq
- The `eta_ai_xai` package shall continue to expose `Eta_ai_xai.Error.t` rather than replacing it with another provider's nominal type. ^aierr-o8ni
- Provider packages shall not retain parallel public operations returning `Eta_ai.ai_error` as compatibility aliases after adopting their nominal error type. ^aierr-le4v

## Open questions

- Which exact Kimi Coding and Moonshot error-envelope fields are published by
  their inference and authentication endpoints?
- Which provider packages can share private implementation helpers without
  making one provider's public error type depend on another provider package?
