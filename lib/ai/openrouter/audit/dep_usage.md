# Dependency Usage Audit

Run: bash lib/ai/openrouter/audit/run.sh
Last updated: 2026-05-24T08:46:44Z
Current sites: 34

Allowed production dependencies for eta-ai-openrouter:

- eta
- eta-ai
- eta-redacted
- eta-http

The package must not depend on OpenAI SDKs, Anthropic SDKs, OpenRouter SDKs,
tokenizer libraries, provider-specific generated clients, or sibling provider
packages. Yojson is allowed for structured JSON.

Search:

    rg -n -t ocaml 'Ai\.|Ai_openai\.|Redacted\.|Http\.|Eta\.(Effect|Redacted|Runtime)|Eio\.|Openai|Anthropic|Tiktoken' lib/ai/openrouter

The search includes Ai_openai to catch forbidden cross-provider usage.

| Site | Dependency | What | Replaceable? | Replacement cost |
| --- | --- | --- | --- | --- |
| eta_ai_openrouter.ml / eta_ai_openrouter.mli | eta-ai | Public provider vocabulary, effects, redacted API keys, and telemetry wrappers. | structural | high; this is the provider package contract. |
| eta_ai_openrouter.ml | eta-redacted | Extract API key value only at the HTTP Authorization header boundary. | structural | low; required by provider auth. |
| eta_ai_openrouter.ml / eta_ai_openrouter.mli | local codec | Responses-style request, response, SSE, structured-output, routing, and OpenRouter error mapping through Ai.Json. | structural | medium; required by the provider dependency policy. |
| eta_ai_openrouter.ml / eta_ai_openrouter.mli | eta-http | Public request/response runner type. | structural | high; AP4 must dogfood eta-http directly. |
| test/test_eta_ai_openrouter.ml | eta / eta-http | Run provider effects against fixture-backed eta-http clients. | replaceable | low; test harness only. |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
- test/ai/openrouter/test_eta_ai_openrouter.ml:3:module E = Eta.Effect
- test/ai/openrouter/test_eta_ai_openrouter.ml:77:  Eio.Switch.run @@ fun sw ->
- test/ai/openrouter/test_eta_ai_openrouter.ml:78:  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
- test/ai/openrouter/test_eta_ai_openrouter.ml:83:  Eio.Switch.run @@ fun sw ->
- test/ai/openrouter/test_eta_ai_openrouter.ml:86:    Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
- test/ai/openrouter/test_eta_ai_openrouter.ml:92:  match Eta.Runtime.run rt effect with
- test/ai/openrouter/test_eta_ai_openrouter.ml:274:    Eta.Runtime.run rt
- lib/ai/openrouter/eta_ai_openrouter.mli:38:  (routing, Ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:43:  ?extra_headers:Ai.headers ->
- lib/ai/openrouter/eta_ai_openrouter.mli:45:  Ai.provider
- lib/ai/openrouter/eta_ai_openrouter.mli:51:  schema_json : Ai.raw_json;
- lib/ai/openrouter/eta_ai_openrouter.mli:58:  schema_json:Ai.raw_json ->
- lib/ai/openrouter/eta_ai_openrouter.mli:60:  (structured_output, Ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:65:  Ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:66:  (Ai.raw_json, Ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:68:val decode_chat : Ai.raw_json -> (Ai.response, Ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:70:  Ai.sse_event -> (Ai.stream_event list, Ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:72:  status:int -> headers:Ai.headers -> Ai.raw_json -> Ai.ai_error
- lib/ai/openrouter/eta_ai_openrouter.mli:77:  ?provider:Ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:78:  api_key:Ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:79:  Ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:80:  (Http.Request.t, Ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:85:  ?provider:Ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:86:  Http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:87:  api_key:Ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:88:  Ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:89:  (Ai.response, Ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:94:  ?provider:Ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:95:  Http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:96:  api_key:Ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:97:  Ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:98:  (Ai.stream, Ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.ml:2:module E = Eta.Effect
- lib/ai/openrouter/eta_ai_openrouter.ml:475:       ("Authorization", "Bearer " ^ Redacted.value api_key);
<!-- END DEP_MATCHES -->
