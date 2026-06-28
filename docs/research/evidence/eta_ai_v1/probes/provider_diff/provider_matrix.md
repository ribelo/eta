# A1 provider matrix

Legend:

- identical - same shape as the eta-ai common concern.
- parametrized-by-data - same operation with provider-specific data fields.
- structurally-different - requires a provider encoder, decoder, or tagged
  variant, not just a value substitution.
- not-applicable - the provider/profile does not expose this concern as a
  separate concept.

Sources checked:

- OpenAI OpenAPI:
  <https://raw.githubusercontent.com/openai/openai-openapi/master/openapi.yaml>
- Anthropic Messages API:
  <https://platform.claude.com/docs/en/api/messages/create.md>
- Anthropic streaming:
  <https://platform.claude.com/docs/en/build-with-claude/streaming.md>
- Anthropic consolidated docs:
  <https://docs.anthropic.com/llms-full.txt>
- OpenRouter chat API:
  <https://openrouter.ai/docs/api/api-reference/chat/send-chat-completion-request.mdx>
- OpenRouter errors:
  <https://openrouter.ai/docs/api/reference/errors-and-debugging.mdx>
- OpenRouter consolidated docs:
  <https://openrouter.ai/docs/llms-full.txt>

| Concern | OpenAI | OpenAI-compatible profile | Anthropic | OpenRouter |
| --- | --- | --- | --- | --- |
| Base URL | parametrized-by-data: https://api.openai.com. | parametrized-by-data: caller/provider config supplies the base URL. | parametrized-by-data: https://api.anthropic.com. | parametrized-by-data: https://openrouter.ai. |
| Path | parametrized-by-data: /v1/chat/completions. | parametrized-by-data: usually /v1/chat/completions. | parametrized-by-data: /v1/messages. | parametrized-by-data: /api/v1/chat/completions. |
| Auth headers | parametrized-by-data: Authorization: Bearer $OPENAI_API_KEY. | parametrized-by-data: usually Authorization: Bearer <token>. | structurally-different: x-api-key plus required anthropic-version; still a provider header function. | parametrized-by-data: Authorization: Bearer $OPENROUTER_API_KEY, plus optional attribution headers such as HTTP-Referer and X-Title/X-OpenRouter-Title. |
| Request operation | identical inside OpenAI family: JSON POST chat completion. | identical to OpenAI profile by definition. | structurally-different: Messages API, not Chat Completions. | identical to OpenAI-style chat completion with extra router fields. |
| System prompt placement | identical: system/developer messages are entries in messages. | identical when the compatible provider honors OpenAI chat messages. | structurally-different: system is top-level; there is no system role in messages. | identical to OpenAI-style messages in public request examples; upstream transformation is router-owned. |
| User/assistant messages | identical: messages[] with roles and content. | identical to OpenAI profile. | structurally-different: messages[] only user/assistant roles, content can be string or typed content block array. | identical to OpenAI-style messages[]; multimodal content is routed through message content parts. |
| Request params | identical for common knobs like model, temperature, stream, tools; exact model IDs are data. | parametrized-by-data: compatible providers may accept a subset/superset. | structurally-different: max_tokens is required in examples/API shape, system is top-level, tool controls use Anthropic names. | parametrized-by-data: OpenAI-style knobs plus OpenRouter provider, routing, transforms, and debug options. |
| Tool definitions | identical: tools[] with function schema and tool choice controls. | identical to OpenAI profile unless a provider lacks tool support. | structurally-different: tools[] entries have name, description, input_schema; tool results are tool_result content blocks. | identical to OpenAI-style tools[], with extra provider-routing behavior. |
| Tool-call response | identical: assistant message has tool_calls[]; finish reason can be tool_calls. | identical to OpenAI profile. | structurally-different: response content includes tool_use blocks and stop_reason: "tool_use". | identical to OpenAI-style response for chat completions. |
| Non-stream response envelope | identical: choices[], message, finish_reason, usage. | identical to OpenAI profile. | structurally-different: top-level message object with content[] blocks and stop_reason. | identical to OpenAI-style choices[], with provider/cost metadata extensions. |
| Streaming transport | identical: SSE over text/event-stream. | identical when compatible provider implements streaming. | identical at transport level: SSE over text/event-stream. | identical: streaming mode emits SSE chunks. |
| Streaming event names | parametrized-by-data: unnamed/default SSE data frames containing chat completion chunks. | parametrized-by-data: OpenAI-compatible data frames. | structurally-different: named events such as message_start, content_block_start, content_block_delta, message_delta, message_stop, ping, and error. | parametrized-by-data: OpenAI-style data frames for chat completions; errors may appear as data chunks after streaming has begun. |
| Streaming delta body | identical: choices[].delta with content and tool-call chunks. | identical to OpenAI profile. | structurally-different: deltas are typed content-block deltas; tool inputs stream through input_json_delta.partial_json. | identical to OpenAI-style choices[].delta, plus possible top-level stream error fields. |
| Streaming terminal marker | parametrized-by-data: terminal data: [DONE] marker. | parametrized-by-data: OpenAI-compatible terminal marker. | structurally-different: terminal state is message_stop, with stop reason in message_delta. | parametrized-by-data: OpenAI-style stream termination for normal chat-completion streams. |
| Streaming errors | structurally-different but local: OpenAI spec has ErrorEvent with event error and error data. | parametrized-by-data or structurally-different depending on provider; must preserve raw error. | structurally-different: named event: error with {"type":"error","error":{...}}. | structurally-different but local: mid-stream errors are SSE data chunks with top-level error and choices[].finish_reason = "error". |
| Non-stream error JSON | identical: {"error":{"type","message","param","code"}}. | parametrized-by-data: OpenAI-compatible APIs often copy OpenAI shape, but raw JSON must be retained. | structurally-different: standard error object carries type and message under error, plus status and request id at HTTP/header level. | structurally-different: {"error":{"code": number, "message": string, "metadata"?: object}}; provider failures preserve upstream raw metadata. |
| Provider routing | not-applicable. | parametrized-by-data only if the compatible provider exposes routing options. | not-applicable for first-party Anthropic API. | parametrized-by-data: provider object, allowed/ignored/order provider settings, fallbacks, and debug upstream body. |
| Raw provider passthrough | not-applicable for first-party core API. | structurally-different by vendor; eta-ai should model capabilities and keep raw JSON escape at provider boundary if needed. | not-applicable for the public Messages shape, except beta headers/features. | parametrized-by-data: OpenRouter explicitly supports provider-specific routing and passthrough/debug options. |

Summary counts:

- Identical: OpenAI-family request/response/tool shapes and shared SSE
  transport.
- Parametrized by data: base URLs, paths, bearer tokens, optional headers,
  model IDs, OpenRouter routing controls, and normal stream terminal markers.
- Structurally different: Anthropic request/response/tool/stream deltas,
  OpenRouter mid-stream errors, and provider-specific error wrappers.

Disproof check:

The disproof signature did not fire. Streaming is structurally different for
Anthropic versus the OpenAI-family providers, and OpenRouter has a local
mid-stream error variant, but the matrix does not show four incompatible
streaming ownership models. A tagged stream event plus a provider-specific SSE
decoder is enough evidence for A1.
