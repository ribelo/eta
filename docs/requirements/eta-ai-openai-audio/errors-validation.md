---
kind: requirement
---
# OpenAI audio errors and validation

## Intent

Preserve every provider and transport failure while rejecting only invalid states
that Eta can establish without guessing account or server policy.

## Requirements

- Every public fallible OpenAI audio constructor, codec, request builder, runner, stream, session, connection, voice, and call-control operation shall use `Eta_ai_openai.Error.t`. ^oaerr-6tam
- When an OpenAI audio HTTP request fails, the OpenAI error shall preserve status, ordered response headers, structured provider payload when decodable, and raw response body. ^oaerr-d5cu
- When OpenAI returns malformed successful audio JSON, the OpenAI provider shall return nominal `Decode` with the available raw body. ^oaerr-yeh9
- When OpenAI returns malformed streamed JSON, the owning stream shall fail through the outer nominal error channel. ^oaerr-noio
- When malformed streamed JSON terminates an OpenAI audio stream, the owning stream shall release its transport exactly once. ^oaerr-wka0
- When OpenAI returns a documented provider failure during streaming, the owning stream shall fail through the outer nominal error channel rather than returning a successful in-band neutral error event. ^oaerr-qt13
- If OpenAI returns an unknown successful JSON event type, then the OpenAI provider shall preserve its event type and complete JSON in an `Unknown` variant. ^oaerr-koau
- Every decoded OpenAI audio JSON record shall retain the complete raw JSON object. ^oaerr-8cu4
- When a caller explicitly projects an OpenAI audio error into `Eta_ai.ai_error`, the projection shall be total. ^oaerr-ebna
- Provider-specific OpenAI audio error facts shall be discarded only when a caller explicitly projects the error into `Eta_ai.ai_error`. ^oaerr-d1rd
- If a caller supplies audio content to OpenAI Responses, then the OpenAI provider shall return nominal `Unsupported` before performing transport. ^oaerr-u6y4
- The OpenAI provider shall not fabricate restricted-access or eligibility errors that only the OpenAI service can establish. ^oaerr-q55h

## Open questions

- Which documented deterministic ranges, cardinalities, mutual exclusions, model restrictions, file-size limits, and keyword constraints shall Eta validate locally?
- Shall exact typed requests expose collision-rejecting extension fields for newly documented JSON and multipart fields?
