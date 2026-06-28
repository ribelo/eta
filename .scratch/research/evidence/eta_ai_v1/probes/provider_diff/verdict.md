# A1 verdict

Status: accepted with constraints.

Decision: eta-ai should start Phase A-C with a provider value shape, not
per-provider modules. The provider value must contain data fields for base URL,
path, headers, and capabilities, plus small provider functions for request
encoding, non-stream response decoding, stream-event decoding, and error
decoding.

Rejected shape: providers-as-data-only. Anthropic is not a field-renaming of
OpenAI. It has a different request envelope, top-level system, content blocks,
tool_use/tool_result blocks, named SSE events, and input_json_delta.partial_json
tool streaming.

Deferred shape: per-provider modules. OCaml modules remain viable if a later
probe finds provider-specific public control flow, but A1 does not justify that
surface. The structural differences are localized codecs, not different Eta
runtime ownership.

Evidence:

- OpenAI exposes /v1/chat/completions, Authorization: Bearer,
  CreateChatCompletionRequest, CreateChatCompletionResponse,
  CreateChatCompletionStreamResponse, tool_calls, choices[].delta,
  data: [DONE], and ErrorResponse.
- Anthropic exposes /v1/messages, x-api-key, anthropic-version, top-level
  system, user/assistant-only messages, content blocks, tools, tool_use,
  tool_result, named stream events, and stream errors.
- OpenRouter exposes /api/v1/chat/completions, bearer auth, OpenAI-style
  request/response fields, OpenAI SDK compatibility, optional attribution
  headers, router/provider fields, and explicit standard plus mid-stream error
  shapes.
- OpenAI-compatible is a profile: configurable base URL and auth with the
  OpenAI chat-completions envelope. It should be represented by provider data
  plus capability flags, not by pretending all compatible providers are
  behaviorally identical.

Disproof signature outcome:

- Not triggered. Streaming is not structurally different across all four
  provider columns. The hard split is OpenAI-family chunk streams versus
  Anthropic named event streams, with OpenRouter adding a local mid-stream
  error variant. This fits a tagged event model and provider stream decoder.

Phase A-C implication:

    (* Sketch only, not production code. *)
    type provider = {
      name : string;
      base_url : string;
      chat_path : string;
      headers : api_key:string -> (string * string) list;
      capabilities : capabilities;
      encode_chat : chat_request -> Json.t;
      decode_chat : Json.t -> (chat_response, ai_error) result;
      decode_stream_event : sse_event -> (stream_event list, ai_error) result;
      decode_error : status:int -> headers:(string * string) list -> Json.t -> ai_error;
    }

The common eta-ai API should expose Eta effects and common domain types. Provider
packages should mostly construct these provider values and should not own
application state.

Open risks:

- The OpenAI-compatible profile can hide vendor-specific quirks. AP3 must keep
  recorded fixtures for at least two real compatible providers before claiming
  broad compatibility.
- A2 still needs to prove that the tagged stream-event model works with bounded
  memory, cancellation, and tool-call delta accumulation over eta-http bodies.
- A3 may change the exact schema type used inside tools; this A1 verdict only
  says provider boundaries can encode/decode tool schemas.
