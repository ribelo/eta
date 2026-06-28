# Dependency Usage Audit

Run: bash lib/ai/anthropic/audit/run.sh
Current sites: 53

Allowed production dependencies for eta-ai-anthropic:

- eta
- eta-ai
- eta-redacted
- eta-http

The package must not depend on Anthropic SDKs, OpenAI SDKs, tokenizer
libraries, provider-specific generated clients, `eta_http_eio`, `eta_http_js`,
Eio, or js_of_ocaml. Yojson is allowed for structured JSON.

Search:

    rg -n -t ocaml 'Eta_ai\.|Eta_redacted\.|Eta_http\.|Eta\.(Effect|Eta_redacted|Runtime)|Eio\.|Openai|Anthropic|Tiktoken' lib/ai/anthropic

| Site | Dependency | What | Replaceable? | Replacement cost |
| --- | --- | --- | --- | --- |
| eta_ai_anthropic.ml / eta_ai_anthropic.mli | eta-ai | Public provider vocabulary, effects, redacted API keys, and telemetry wrappers. | structural | high; this is the provider package contract. |
| eta_ai_anthropic.ml | eta-redacted | Extract API key value only at the x-api-key header boundary. | structural | low; required by provider auth. |
| eta_ai_anthropic.ml / eta_ai_anthropic.mli | eta-http | Build and submit HTTP requests through eta-http. | structural | high; AP2 must dogfood eta-http. |
| bench/bench_ai_anthropic.ml | eta-ai | Build representative provider requests for package benchmarks. | replaceable | low; benchmark harness only. |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
- lib/ai/anthropic/bench/bench_ai_anthropic.ml:2:  Eta_ai.Json.to_string
- lib/ai/anthropic/bench/bench_ai_anthropic.ml:3:    (Eta_ai.Json.object_
- lib/ai/anthropic/bench/bench_ai_anthropic.ml:5:         ("type", Some (Eta_ai.Json.string "object"));
- lib/ai/anthropic/bench/bench_ai_anthropic.ml:8:             (Eta_ai.Json.object_
- lib/ai/anthropic/bench/bench_ai_anthropic.ml:12:                      (Eta_ai.Json.object_
- lib/ai/anthropic/bench/bench_ai_anthropic.ml:13:                         [ ("type", Some (Eta_ai.Json.string "string")) ]) );
- lib/ai/anthropic/bench/bench_ai_anthropic.ml:22:  Eta_ai.make_tool ~name:"weather" ~description:"Get current weather"
- lib/ai/anthropic/bench/bench_ai_anthropic.ml:26:let request : Eta_ai.chat_request =
- lib/ai/anthropic/bench/bench_ai_anthropic.ml:57:              (Eta_ai_anthropic.messages_request ~provider ~api_key:(Eta_ai.api_key "sk-bench")
- lib/ai/anthropic/eta_ai_anthropic.ml:2:module E = Eta.Effect
- lib/ai/anthropic/eta_ai_anthropic.ml:484:    | headers -> [ ("Anthropic-Beta", String.concat "," headers) ]
- lib/ai/anthropic/eta_ai_anthropic.ml:488:       ("x-api-key", Eta_redacted.value api_key);
- lib/ai/anthropic/eta_ai_anthropic.ml:545:      |> H.Core.Header.unsafe_add "Anthropic-Beta" value
- lib/ai/anthropic/eta_ai_anthropic.mli:1:(** Anthropic Messages provider.
- lib/ai/anthropic/eta_ai_anthropic.mli:4:    text is encoded through Anthropic's top-level [system] field, tool results
- lib/ai/anthropic/eta_ai_anthropic.mli:14:    [beta_header] is added as [Anthropic-Beta]. When [cache_system] is true,
- lib/ai/anthropic/eta_ai_anthropic.mli:15:    system text is encoded as an Anthropic text block with ephemeral
- lib/ai/anthropic/eta_ai_anthropic.mli:26:  Eta_ai.provider
- lib/ai/anthropic/eta_ai_anthropic.mli:31:  include Eta_ai.Provider.Chat
- lib/ai/anthropic/eta_ai_anthropic.mli:35:    ?provider:Eta_ai.provider ->
- lib/ai/anthropic/eta_ai_anthropic.mli:36:    api_key:Eta_ai.api_key ->
- lib/ai/anthropic/eta_ai_anthropic.mli:37:    Eta_ai.chat_request ->
- lib/ai/anthropic/eta_ai_anthropic.mli:38:    (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/anthropic/eta_ai_anthropic.mli:42:    ?provider:Eta_ai.provider ->
- lib/ai/anthropic/eta_ai_anthropic.mli:43:    Eta_http.Client.t ->
- lib/ai/anthropic/eta_ai_anthropic.mli:44:    api_key:Eta_ai.api_key ->
- lib/ai/anthropic/eta_ai_anthropic.mli:45:    Eta_ai.chat_request ->
- lib/ai/anthropic/eta_ai_anthropic.mli:46:    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/anthropic/eta_ai_anthropic.mli:50:    ?provider:Eta_ai.provider ->
- lib/ai/anthropic/eta_ai_anthropic.mli:51:    Eta_http.Client.t ->
- lib/ai/anthropic/eta_ai_anthropic.mli:52:    api_key:Eta_ai.api_key ->
- lib/ai/anthropic/eta_ai_anthropic.mli:53:    Eta_ai.chat_request ->
- lib/ai/anthropic/eta_ai_anthropic.mli:54:    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/anthropic/eta_ai_anthropic.mli:57:module Embeddings : Eta_ai.Provider.Embeddings
- lib/ai/anthropic/eta_ai_anthropic.mli:61:  Eta_ai.chat_request ->
- lib/ai/anthropic/eta_ai_anthropic.mli:62:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/anthropic/eta_ai_anthropic.mli:64:val decode_message : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
- lib/ai/anthropic/eta_ai_anthropic.mli:66:  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result
- lib/ai/anthropic/eta_ai_anthropic.mli:68:  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error
- lib/ai/anthropic/eta_ai_anthropic.mli:72:  ?provider:Eta_ai.provider ->
- lib/ai/anthropic/eta_ai_anthropic.mli:73:  api_key:Eta_ai.api_key ->
- lib/ai/anthropic/eta_ai_anthropic.mli:74:  Eta_ai.chat_request ->
- lib/ai/anthropic/eta_ai_anthropic.mli:75:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/anthropic/eta_ai_anthropic.mli:79:  ?provider:Eta_ai.provider ->
- lib/ai/anthropic/eta_ai_anthropic.mli:80:  Eta_http.Client.t ->
- lib/ai/anthropic/eta_ai_anthropic.mli:81:  api_key:Eta_ai.api_key ->
- lib/ai/anthropic/eta_ai_anthropic.mli:82:  Eta_ai.chat_request ->
- lib/ai/anthropic/eta_ai_anthropic.mli:83:  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/anthropic/eta_ai_anthropic.mli:87:  ?provider:Eta_ai.provider ->
- lib/ai/anthropic/eta_ai_anthropic.mli:88:  Eta_http.Client.t ->
- lib/ai/anthropic/eta_ai_anthropic.mli:89:  api_key:Eta_ai.api_key ->
- lib/ai/anthropic/eta_ai_anthropic.mli:90:  Eta_ai.chat_request ->
- lib/ai/anthropic/eta_ai_anthropic.mli:91:  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
<!-- END DEP_MATCHES -->
