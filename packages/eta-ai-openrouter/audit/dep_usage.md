# Dependency Usage Audit

Run: bash packages/eta-ai-openrouter/audit/run.sh
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

    rg -n -t ocaml 'Eta_ai\.|Eta_ai_openai\.|Eta_redacted\.|Eta_http\.|Eta\.(Effect|Redacted|Runtime)|Eio\.|Openai|Anthropic|Tiktoken' packages/eta-ai-openrouter

The search includes Eta_ai_openai to catch forbidden cross-provider usage.

| Site | Dependency | What | Replaceable? | Replacement cost |
| --- | --- | --- | --- | --- |
| eta_ai_openrouter.ml / eta_ai_openrouter.mli | eta-ai | Public provider vocabulary, effects, redacted API keys, and telemetry wrappers. | structural | high; this is the provider package contract. |
| eta_ai_openrouter.ml | eta-redacted | Extract API key value only at the HTTP Authorization header boundary. | structural | low; required by provider auth. |
| eta_ai_openrouter.ml / eta_ai_openrouter.mli | local codec | Responses-style request, response, SSE, structured-output, routing, and OpenRouter error mapping through Eta_ai.Json. | structural | medium; required by the provider dependency policy. |
| eta_ai_openrouter.ml / eta_ai_openrouter.mli | eta-http | Public request/response runner type. | structural | high; AP4 must dogfood eta-http directly. |
| test/test_eta_ai_openrouter.ml | eta / eta-http | Run provider effects against fixture-backed eta-http clients. | replaceable | low; test harness only. |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
- packages/eta-ai-openrouter/test/test_eta_ai_openrouter.ml:3:module E = Eta.Effect
- packages/eta-ai-openrouter/test/test_eta_ai_openrouter.ml:77:  Eio.Switch.run @@ fun sw ->
- packages/eta-ai-openrouter/test/test_eta_ai_openrouter.ml:78:  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
- packages/eta-ai-openrouter/test/test_eta_ai_openrouter.ml:83:  Eio.Switch.run @@ fun sw ->
- packages/eta-ai-openrouter/test/test_eta_ai_openrouter.ml:86:    Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
- packages/eta-ai-openrouter/test/test_eta_ai_openrouter.ml:92:  match Eta.Runtime.run rt effect with
- packages/eta-ai-openrouter/test/test_eta_ai_openrouter.ml:274:    Eta.Runtime.run rt
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:38:  (routing, Eta_ai.ai_error) result
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:43:  ?extra_headers:Eta_ai.headers ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:45:  Eta_ai.provider
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:51:  schema_json : Eta_ai.raw_json;
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:58:  schema_json:Eta_ai.raw_json ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:60:  (structured_output, Eta_ai.ai_error) result
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:65:  Eta_ai.chat_request ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:66:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:68:val decode_chat : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:70:  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:72:  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:77:  ?provider:Eta_ai.provider ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:78:  api_key:Eta_ai.api_key ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:79:  Eta_ai.chat_request ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:80:  (Eta_http.Request.t, Eta_ai.ai_error) result
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:85:  ?provider:Eta_ai.provider ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:86:  Eta_http.Client.t ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:87:  api_key:Eta_ai.api_key ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:88:  Eta_ai.chat_request ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:89:  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:94:  ?provider:Eta_ai.provider ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:95:  Eta_http.Client.t ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:96:  api_key:Eta_ai.api_key ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:97:  Eta_ai.chat_request ->
- packages/eta-ai-openrouter/eta_ai_openrouter.mli:98:  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- packages/eta-ai-openrouter/eta_ai_openrouter.ml:2:module E = Eta.Effect
- packages/eta-ai-openrouter/eta_ai_openrouter.ml:475:       ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
<!-- END DEP_MATCHES -->
