# Dependency Usage Audit

Run: bash lib/ai/openai/audit/run.sh
Last updated: 2026-05-24T08:46:44Z
Current sites: 45

Allowed production dependencies for eta-ai-openai:

- eta
- eta-ai
- eta-redacted
- eta-http

The package must not depend on OpenAI SDKs, tokenizer libraries, or
provider-specific generated clients. Yojson is allowed for structured JSON.

Search:

    rg -n -t ocaml 'Eta_ai\.|Eta_redacted\.|Eta_http\.|Eta\.(Effect|Eta_redacted|Runtime)|Eio\.|Openai|Anthropic|Tiktoken' lib/ai/openai

| Site | Dependency | What | Replaceable? | Replacement cost |
| --- | --- | --- | --- | --- |
| eta_ai_openai.ml / eta_ai_openai.mli | eta-ai | Public provider vocabulary, effects, redacted API keys, and telemetry wrappers. | structural | high; this is the provider package contract. |
| eta_ai_openai.ml | eta-redacted | Extract API key value only at the HTTP Authorization header boundary. | structural | low; required by provider auth. |
| eta_ai_openai.ml / eta_ai_openai.mli | eta-http | Build and submit HTTP requests through eta-http. | structural | high; AP1 must dogfood eta-http. |
| test/test_eta_ai_openai.ml | eta / eta-http | Run provider effects against fixture-backed eta-http clients. | replaceable | low; test harness only. |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
- test/ai/openai/test_eta_ai_openai.ml:3:module E = Eta.Effect
- test/ai/openai/test_eta_ai_openai.ml:77:  Eio.Switch.run @@ fun sw ->
- test/ai/openai/test_eta_ai_openai.ml:78:  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
- test/ai/openai/test_eta_ai_openai.ml:83:  Eio.Switch.run @@ fun sw ->
- test/ai/openai/test_eta_ai_openai.ml:86:    Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
- test/ai/openai/test_eta_ai_openai.ml:92:  match Eta.Runtime.run rt effect with
- test/ai/openai/test_eta_ai_openai.ml:319:    Eta.Runtime.run rt
- lib/ai/openai/eta_ai_openai.mli:9:  schema_json : Eta_ai.raw_json;
- lib/ai/openai/eta_ai_openai.mli:18:  schema_json:Eta_ai.raw_json ->
- lib/ai/openai/eta_ai_openai.mli:20:  (structured_output, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:22:val provider : ?base_url:string -> unit -> Eta_ai.provider
- lib/ai/openai/eta_ai_openai.mli:26:val responses_provider : ?base_url:string -> unit -> Eta_ai.provider
- lib/ai/openai/eta_ai_openai.mli:32:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:33:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:37:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:38:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:40:val decode_chat : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:41:val decode_responses : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:43:  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:45:  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error
- lib/ai/openai/eta_ai_openai.mli:49:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:50:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:51:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:52:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:56:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:57:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:58:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:59:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:63:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:64:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:65:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:66:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:67:  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:71:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:72:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:73:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:74:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:75:  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:79:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:80:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:81:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:82:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:83:  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.ml:2:module E = Eta.Effect
- lib/ai/openai/eta_ai_openai.ml:938:      ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
<!-- END DEP_MATCHES -->
