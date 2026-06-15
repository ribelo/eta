# Dependency Usage Audit

Run: bash lib/ai/openai_compat/audit/run.sh
Last updated: 2026-06-15T22:49:12Z
Current sites: 51

Allowed production dependencies for eta-ai-openai-compat:

- eta
- eta-ai
- eta-redacted
- eta-http

The package must not depend on OpenAI SDKs, Anthropic SDKs, tokenizer
libraries, provider-specific generated clients, or sibling provider packages.
Yojson is allowed for structured JSON.

Search:

    rg -n -t ocaml 'Eta_ai\.|Eta_ai_openai\.|Eta_redacted\.|Eta_http\.|Eta\.(Effect|Eta_redacted|Runtime)|Eio\.|Openai|Anthropic|Tiktoken' lib/ai/openai_compat

The search includes Eta_ai_openai to catch forbidden cross-provider usage.

| Site | Dependency | What | Replaceable? | Replacement cost |
| --- | --- | --- | --- | --- |
| eta_ai_openai_compat.ml / eta_ai_openai_compat.mli | eta-ai | Public provider vocabulary, effects, redacted API keys, and telemetry wrappers. | structural | high; this is the provider package contract. |
| eta_ai_openai_compat.ml | eta-redacted | Extract API key value only at the configured auth header boundary. | structural | low; required by provider auth. |
| eta_ai_openai_compat.ml / eta_ai_openai_compat.mli | local codec | OpenAI-compatible request, response, SSE, structured-output, and error mapping without a JSON library dependency. | structural | medium; required by the provider dependency policy. |
| eta_ai_openai_compat.ml / eta_ai_openai_compat.mli | eta-http | Public request/response runner type. | structural | high; AP3 must dogfood eta-http directly. |
| bench/bench_ai_openai_compat.ml | eta-ai | Build representative provider requests for package benchmarks. | replaceable | low; benchmark harness only. |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
- lib/ai/openai_compat/bench/bench_ai_openai_compat.ml:2:  Eta_ai.Json.to_string
- lib/ai/openai_compat/bench/bench_ai_openai_compat.ml:3:    (Eta_ai.Json.object_
- lib/ai/openai_compat/bench/bench_ai_openai_compat.ml:5:         ("type", Some (Eta_ai.Json.string "object"));
- lib/ai/openai_compat/bench/bench_ai_openai_compat.ml:8:             (Eta_ai.Json.object_
- lib/ai/openai_compat/bench/bench_ai_openai_compat.ml:12:                      (Eta_ai.Json.object_
- lib/ai/openai_compat/bench/bench_ai_openai_compat.ml:13:                         [ ("type", Some (Eta_ai.Json.string "string")) ]) );
- lib/ai/openai_compat/bench/bench_ai_openai_compat.ml:22:  Eta_ai.make_tool ~name:"weather" ~description:"Get current weather"
- lib/ai/openai_compat/bench/bench_ai_openai_compat.ml:26:let request : Eta_ai.chat_request =
- lib/ai/openai_compat/bench/bench_ai_openai_compat.ml:62:                 ~api_key:(Eta_ai.api_key "sk-bench") request)));
- lib/ai/openai_compat/eta_ai_openai_compat.mli:17:  schema : Eta_ai.Json.t;
- lib/ai/openai_compat/eta_ai_openai_compat.mli:24:  schema_json:Eta_ai.raw_json ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:26:  (structured_output, Eta_ai.ai_error) result
- lib/ai/openai_compat/eta_ai_openai_compat.mli:40:  ?extra_headers:Eta_ai.headers ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:43:  Eta_ai.provider
- lib/ai/openai_compat/eta_ai_openai_compat.mli:47:  include Eta_ai.Provider.Chat
- lib/ai/openai_compat/eta_ai_openai_compat.mli:51:    provider:Eta_ai.provider ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:52:    api_key:Eta_ai.api_key ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:53:    Eta_ai.chat_request ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:54:    (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai_compat/eta_ai_openai_compat.mli:58:    provider:Eta_ai.provider ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:59:    Eta_http.Client.t ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:60:    api_key:Eta_ai.api_key ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:61:    Eta_ai.chat_request ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:62:    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai_compat/eta_ai_openai_compat.mli:66:    provider:Eta_ai.provider ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:67:    Eta_http.Client.t ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:68:    api_key:Eta_ai.api_key ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:69:    Eta_ai.chat_request ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:70:    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai_compat/eta_ai_openai_compat.mli:74:  include Eta_ai.Provider.Embeddings
- lib/ai/openai_compat/eta_ai_openai_compat.mli:79:  Eta_ai.chat_request ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:80:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openai_compat/eta_ai_openai_compat.mli:82:val decode_chat : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
- lib/ai/openai_compat/eta_ai_openai_compat.mli:84:  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result
- lib/ai/openai_compat/eta_ai_openai_compat.mli:86:  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error
- lib/ai/openai_compat/eta_ai_openai_compat.mli:90:  provider:Eta_ai.provider ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:91:  api_key:Eta_ai.api_key ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:92:  Eta_ai.chat_request ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:93:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai_compat/eta_ai_openai_compat.mli:97:  provider:Eta_ai.provider ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:98:  Eta_http.Client.t ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:99:  api_key:Eta_ai.api_key ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:100:  Eta_ai.chat_request ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:101:  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai_compat/eta_ai_openai_compat.mli:105:  provider:Eta_ai.provider ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:106:  Eta_http.Client.t ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:107:  api_key:Eta_ai.api_key ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:108:  Eta_ai.chat_request ->
- lib/ai/openai_compat/eta_ai_openai_compat.mli:109:  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai_compat/eta_ai_openai_compat.ml:3:module E = Eta.Effect
- lib/ai/openai_compat/eta_ai_openai_compat.ml:35:  Option.value ~default:"" auth.prefix ^ Eta_redacted.value api_key
<!-- END DEP_MATCHES -->
