# Dependency Usage Audit

Run: bash lib/ai/openai/audit/run.sh
Last updated: 2026-06-20T16:49:09Z
Current sites: 148

Allowed production dependencies for eta-ai-openai:

- eta
- eta-ai
- eta-redacted
- eta-http

The package must not depend on OpenAI SDKs, tokenizer libraries,
provider-specific generated clients, `eta_http_eio`, `eta_http_js`, Eio, or
js_of_ocaml. Yojson is allowed for structured JSON.

Search:

    rg -n -t ocaml 'Eta_ai\.|Eta_redacted\.|Eta_http\.|Eta\.(Effect|Eta_redacted|Runtime)|Eio\.|Openai|Anthropic|Tiktoken' lib/ai/openai

| Site | Dependency | What | Replaceable? | Replacement cost |
| --- | --- | --- | --- | --- |
| eta_ai_openai.ml / eta_ai_openai.mli | eta-ai | Public provider vocabulary, effects, redacted API keys, and telemetry wrappers. | structural | high; this is the provider package contract. |
| eta_ai_openai.ml | eta-redacted | Extract API key value only at the HTTP Authorization header boundary. | structural | low; required by provider auth. |
| eta_ai_openai.ml / eta_ai_openai.mli | eta-http | Build and submit HTTP requests through eta-http. | structural | high; AP1 must dogfood eta-http. |
| bench/bench_ai_openai.ml | eta-ai | Build representative provider requests for package benchmarks. | replaceable | low; benchmark harness only. |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
- lib/ai/openai/bench/bench_ai_openai.ml:2:  Eta_ai.Json.to_string
- lib/ai/openai/bench/bench_ai_openai.ml:3:    (Eta_ai.Json.object_
- lib/ai/openai/bench/bench_ai_openai.ml:5:         ("type", Some (Eta_ai.Json.string "object"));
- lib/ai/openai/bench/bench_ai_openai.ml:8:             (Eta_ai.Json.object_
- lib/ai/openai/bench/bench_ai_openai.ml:12:                      (Eta_ai.Json.object_
- lib/ai/openai/bench/bench_ai_openai.ml:13:                         [ ("type", Some (Eta_ai.Json.string "string")) ]) );
- lib/ai/openai/bench/bench_ai_openai.ml:22:  Eta_ai.make_tool ~name:"weather" ~description:"Get current weather"
- lib/ai/openai/bench/bench_ai_openai.ml:26:let request : Eta_ai.chat_request =
- lib/ai/openai/bench/bench_ai_openai.ml:64:                 ~api_key:(Eta_ai.api_key "sk-bench") request)));
- lib/ai/openai/eta_ai_openai.mli:12:  schema : Eta_ai.Json.t;
- lib/ai/openai/eta_ai_openai.mli:21:  schema_json:Eta_ai.raw_json ->
- lib/ai/openai/eta_ai_openai.mli:23:  (structured_output, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:25:val provider : ?base_url:string -> unit -> Eta_ai.provider
- lib/ai/openai/eta_ai_openai.mli:29:val chat_completions_provider : ?base_url:string -> unit -> Eta_ai.provider
- lib/ai/openai/eta_ai_openai.mli:33:val responses_provider : ?base_url:string -> unit -> Eta_ai.provider
- lib/ai/openai/eta_ai_openai.mli:38:  include Eta_ai.Provider.Chat
- lib/ai/openai/eta_ai_openai.mli:42:    ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:43:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:44:    Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:45:    (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:49:    ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:50:    Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:51:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:52:    Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:53:    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:57:    ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:58:    Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:59:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:60:    Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:61:    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:64:module Embeddings : Eta_ai.Provider.Embeddings
- lib/ai/openai/eta_ai_openai.mli:65:module Images : Eta_ai.Provider.Images
- lib/ai/openai/eta_ai_openai.mli:66:module Speech : Eta_ai.Provider.Speech
- lib/ai/openai/eta_ai_openai.mli:67:module Transcriptions : Eta_ai.Provider.Transcriptions
- lib/ai/openai/eta_ai_openai.mli:71:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:72:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:76:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:77:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:79:val decode_chat : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:80:val decode_responses : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:82:  Eta_ai.Embedding.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:84:  Eta_ai.raw_json -> (Eta_ai.Embedding.response, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:86:  Eta_ai.Image.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:88:  Eta_ai.raw_json -> (Eta_ai.Image.response, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:90:  Eta_ai.Speech.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:92:  Eta_ai.raw_json -> (Eta_ai.Transcription.response, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:94:  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:96:  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error
- lib/ai/openai/eta_ai_openai.mli:102:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:103:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:104:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:105:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:109:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:110:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:111:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:112:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:115:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:116:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:117:  Eta_ai.Embedding.request ->
- lib/ai/openai/eta_ai_openai.mli:118:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:121:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:122:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:123:  Eta_ai.Image.request ->
- lib/ai/openai/eta_ai_openai.mli:124:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:127:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:128:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:129:  Eta_ai.Speech.request ->
- lib/ai/openai/eta_ai_openai.mli:130:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:133:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:134:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:135:  Eta_ai.Transcription.request ->
- lib/ai/openai/eta_ai_openai.mli:136:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:140:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:141:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:142:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:143:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:144:  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:148:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:149:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:150:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:151:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:152:  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:155:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:156:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:157:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:158:  Eta_ai.Embedding.request ->
- lib/ai/openai/eta_ai_openai.mli:159:  (Eta_ai.Embedding.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:162:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:163:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:164:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:165:  Eta_ai.Image.request ->
- lib/ai/openai/eta_ai_openai.mli:166:  (Eta_ai.Image.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:169:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:170:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:171:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:172:  Eta_ai.Speech.request ->
- lib/ai/openai/eta_ai_openai.mli:173:  (Eta_ai.Speech.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:176:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:177:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:178:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:179:  Eta_ai.Transcription.request ->
- lib/ai/openai/eta_ai_openai.mli:180:  (Eta_ai.Transcription.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:184:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:185:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:186:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:187:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:188:  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:192:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:193:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:194:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:195:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:196:  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/common.ml:49:  Eta_http.Core.Header.unsafe_of_list
- lib/ai/openai/common.ml:51:      ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
- lib/ai/openai/realtime.mli:9:  input_audio_format : Eta_ai.audio_format option;
- lib/ai/openai/realtime.mli:10:  output_audio_format : Eta_ai.audio_format option;
- lib/ai/openai/realtime.mli:12:  turn_detection : Eta_ai.Json.t option;
- lib/ai/openai/realtime.mli:13:  tools : Eta_ai.Json.t option;
- lib/ai/openai/realtime.mli:22:  ?input_audio_format:Eta_ai.audio_format ->
- lib/ai/openai/realtime.mli:23:  ?output_audio_format:Eta_ai.audio_format ->
- lib/ai/openai/realtime.mli:25:  ?turn_detection:Eta_ai.Json.t ->
- lib/ai/openai/realtime.mli:26:  ?tools:Eta_ai.Json.t ->
- lib/ai/openai/realtime.mli:32:val session_json : session -> Eta_ai.Json.t
- lib/ai/openai/realtime.mli:33:val session_to_string : session -> Eta_ai.raw_json
- lib/ai/openai/realtime.mli:38:  raw : Eta_ai.raw_json option;
- lib/ai/openai/realtime.mli:42:  ?base_url:string -> api_key:Eta_ai.api_key -> session -> Eta_http.Request.t
- lib/ai/openai/realtime.mli:46:  Eta_http.Client.t ->
- lib/ai/openai/realtime.mli:47:  api_key:Eta_ai.api_key ->
- lib/ai/openai/realtime.mli:49:  (client_secret, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/realtime.mli:53:  | Input_audio_buffer_append of Eta_ai.audio
- lib/ai/openai/realtime.mli:56:  | Raw_client_event of Eta_ai.Json.t
- lib/ai/openai/realtime.mli:61:  raw : Eta_ai.raw_json option;
- lib/ai/openai/realtime.mli:65:  | Session_created of Eta_ai.raw_json option
- lib/ai/openai/realtime.mli:68:  | Response_done of Eta_ai.raw_json option
- lib/ai/openai/realtime.mli:71:  | Server_decode_error of { message : string; raw : Eta_ai.raw_json option }
- lib/ai/openai/realtime.mli:72:  | Raw_server_event of { type_ : string option; raw : Eta_ai.raw_json }
- lib/ai/openai/realtime.mli:74:val client_event_json : client_event -> Eta_ai.Json.t
- lib/ai/openai/realtime.mli:75:val client_event_to_string : client_event -> Eta_ai.raw_json
- lib/ai/openai/realtime.mli:76:val decode_server_event : Eta_ai.raw_json -> server_event
- lib/ai/openai/realtime.ml:3:module E = Eta.Effect
- lib/ai/openai/realtime.ml:98:  Eta_http.Core.Header.unsafe_of_list
- lib/ai/openai/realtime.ml:100:      ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
- lib/ai/openai/realtime.ml:109:  Eta_http.Request.make ~headers:(auth_headers api_key)
- lib/ai/openai/realtime.ml:110:    ~body:(Eta_http.Request.Fixed [ Bytes.of_string body ])
- lib/ai/openai/realtime.ml:115:  Eta_http.Body.Stream.read_all body
- lib/ai/openai/realtime.ml:138:  Eta_http.request client request
- lib/ai/openai/realtime.ml:141:  |> E.bind (fun (response : Eta_http.Response.t) ->
- lib/ai/openai/realtime.ml:142:         read_response_body response.Eta_http.Response.body
<!-- END DEP_MATCHES -->
