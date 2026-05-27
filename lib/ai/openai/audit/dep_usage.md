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

    rg -n -t ocaml 'Ai\.|Redacted\.|Http\.|Eta\.(Effect|Redacted|Runtime)|Eio\.|Openai|Anthropic|Tiktoken' lib/ai/openai

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
- lib/ai/openai/eta_ai_openai.mli:9:  schema_json : Ai.raw_json;
- lib/ai/openai/eta_ai_openai.mli:18:  schema_json:Ai.raw_json ->
- lib/ai/openai/eta_ai_openai.mli:20:  (structured_output, Ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:22:val provider : ?base_url:string -> unit -> Ai.provider
- lib/ai/openai/eta_ai_openai.mli:26:val responses_provider : ?base_url:string -> unit -> Ai.provider
- lib/ai/openai/eta_ai_openai.mli:32:  Ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:33:  (Ai.raw_json, Ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:37:  Ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:38:  (Ai.raw_json, Ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:40:val decode_chat : Ai.raw_json -> (Ai.response, Ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:41:val decode_responses : Ai.raw_json -> (Ai.response, Ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:43:  Ai.sse_event -> (Ai.stream_event list, Ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:45:  status:int -> headers:Ai.headers -> Ai.raw_json -> Ai.ai_error
- lib/ai/openai/eta_ai_openai.mli:49:  ?provider:Ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:50:  api_key:Ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:51:  Ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:52:  (Http.Request.t, Ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:56:  ?provider:Ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:57:  api_key:Ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:58:  Ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:59:  (Http.Request.t, Ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:63:  ?provider:Ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:64:  Http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:65:  api_key:Ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:66:  Ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:67:  (Ai.response, Ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:71:  ?provider:Ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:72:  Http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:73:  api_key:Ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:74:  Ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:75:  (Ai.response, Ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:79:  ?provider:Ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:80:  Http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:81:  api_key:Ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:82:  Ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:83:  (Ai.stream, Ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.ml:2:module E = Eta.Effect
- lib/ai/openai/eta_ai_openai.ml:938:      ("Authorization", "Bearer " ^ Redacted.value api_key);
<!-- END DEP_MATCHES -->
