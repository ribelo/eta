# Dependency Usage Audit

Run: bash lib/ai/openai_compat/audit/run.sh
Last updated: 2026-05-24T08:46:44Z
Current sites: 33

Allowed production dependencies for eta-ai-openai-compat:

- eta
- eta-ai
- eta-redacted
- eta-http

The package must not depend on OpenAI SDKs, Anthropic SDKs, tokenizer
libraries, provider-specific generated clients, or sibling provider packages.
Yojson is allowed for structured JSON.

Search:

    rg -n -t ocaml 'Ai\.|Ai_openai\.|Redacted\.|Http\.|Eta\.(Effect|Redacted|Runtime)|Eio\.|Openai|Anthropic|Tiktoken' lib/ai/openai_compat

The search includes Ai_openai to catch forbidden cross-provider usage.

| Site | Dependency | What | Replaceable? | Replacement cost |
| --- | --- | --- | --- | --- |
| eta_ai_openai_compat.ml / eta_ai_openai_compat.mli | eta-ai | Public provider vocabulary, effects, redacted API keys, and telemetry wrappers. | structural | high; this is the provider package contract. |
| eta_ai_openai_compat.ml | eta-redacted | Extract API key value only at the configured auth header boundary. | structural | low; required by provider auth. |
| eta_ai_openai_compat.ml / eta_ai_openai_compat.mli | local codec | OpenAI-compatible request, response, SSE, structured-output, and error mapping without a JSON library dependency. | structural | medium; required by the provider dependency policy. |
| eta_ai_openai_compat.ml / eta_ai_openai_compat.mli | eta-http | Public request/response runner type. | structural | high; AP3 must dogfood eta-http directly. |
| test/test_eta_ai_openai_compat.ml | eta / eta-http | Run provider effects against fixture-backed eta-http clients. | replaceable | low; test harness only. |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:16:  schema_json : Ai.raw_json;
- lib/ai/openai_compat/eta_ai_openai_compat.mli:23:  schema_json:Ai.raw_json ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:25:  (structured_output, Ai.ai_error) result
- lib/ai/openai_compat/eta_ai_openai_compat.mli:39:  ?extra_headers:Ai.headers ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:42:  Ai.provider
- lib/ai/openai_compat/eta_ai_openai_compat.mli:47:  Ai.chat_request ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:48:  (Ai.raw_json, Ai.ai_error) result
- lib/ai/openai_compat/eta_ai_openai_compat.mli:50:val decode_chat : Ai.raw_json -> (Ai.response, Ai.ai_error) result
- lib/ai/openai_compat/eta_ai_openai_compat.mli:52:  Ai.sse_event -> (Ai.stream_event list, Ai.ai_error) result
- lib/ai/openai_compat/eta_ai_openai_compat.mli:54:  status:int -> headers:Ai.headers -> Ai.raw_json -> Ai.ai_error
- lib/ai/openai_compat/eta_ai_openai_compat.mli:58:  provider:Ai.provider ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:59:  api_key:Ai.api_key ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:60:  Ai.chat_request ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:61:  (Http.Request.t, Ai.ai_error) result
- lib/ai/openai_compat/eta_ai_openai_compat.mli:65:  provider:Ai.provider ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:66:  Http.Client.t ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:67:  api_key:Ai.api_key ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:68:  Ai.chat_request ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:69:  (Ai.response, Ai.ai_error) Eta.Effect.t
- lib/ai/openai_compat/eta_ai_openai_compat.mli:73:  provider:Ai.provider ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:74:  Http.Client.t ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:75:  api_key:Ai.api_key ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:76:  Ai.chat_request ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:77:  (Ai.stream, Ai.ai_error) Eta.Effect.t
- lib/ai/openai_compat/eta_ai_openai_compat.ml:2:module E = Eta.Effect
- lib/ai/openai_compat/eta_ai_openai_compat.ml:81:  Option.value ~default:"" auth.prefix ^ Redacted.value api_key
- test/ai/openai_compat/test_eta_ai_openai_compat.ml:3:module E = Eta.Effect
- test/ai/openai_compat/test_eta_ai_openai_compat.ml:78:  Eio.Switch.run @@ fun sw ->
- test/ai/openai_compat/test_eta_ai_openai_compat.ml:79:  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
- test/ai/openai_compat/test_eta_ai_openai_compat.ml:84:  Eio.Switch.run @@ fun sw ->
- test/ai/openai_compat/test_eta_ai_openai_compat.ml:87:    Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
- test/ai/openai_compat/test_eta_ai_openai_compat.ml:93:  match Eta.Runtime.run rt effect with
- test/ai/openai_compat/test_eta_ai_openai_compat.ml:294:    Eta.Runtime.run rt
<!-- END DEP_MATCHES -->
