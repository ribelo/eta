# Dependency Usage Audit

Run: bash lib/ai/openai/audit/run.sh
Last updated: 2026-05-28T19:07:34Z
Current sites: 160

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
- lib/ai/openai/bench/bench_ai_openai.ml:9:  Eta_ai.make_tool ~name:"weather" ~description:"Get current weather"
- lib/ai/openai/bench/bench_ai_openai.ml:13:let request : Eta_ai.chat_request =
- lib/ai/openai/bench/bench_ai_openai.ml:51:                 ~api_key:(Eta_ai.api_key "sk-bench") request)));
- lib/ai/openai/eta_ai_openai.ml:3:module E = Eta.Effect
- lib/ai/openai/eta_ai_openai.ml:185:  Eta_http.Core.Header.unsafe_of_list
- lib/ai/openai/eta_ai_openai.ml:187:      ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
- lib/ai/openai/realtime.ml:2:module E = Eta.Effect
- lib/ai/openai/realtime.ml:100:  Eta_http.Core.Header.unsafe_of_list
- lib/ai/openai/realtime.ml:102:      ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
- lib/ai/openai/realtime.ml:111:  Eta_http.Request.make ~headers:(auth_headers api_key)
- lib/ai/openai/realtime.ml:112:    ~body:(Eta_http.Request.Fixed [ Bytes.of_string body ])
- lib/ai/openai/realtime.ml:117:  Eta_http.Body.Stream.read_all body
- lib/ai/openai/realtime.ml:140:  Eta_http.request client request
- lib/ai/openai/realtime.ml:143:  |> E.bind (fun (response : Eta_http.Response.t) ->
- lib/ai/openai/realtime.ml:144:         read_response_body response.Eta_http.Response.body
- lib/ai/openai/realtime.ml:178:type realtime_error = [ Eta_http.Ws.Client.ws_error | `Encode of string ]
- lib/ai/openai/realtime.ml:180:let widen_ws_error (error : Eta_http.Ws.Client.ws_error) : realtime_error =
- lib/ai/openai/realtime.ml:266:type t = { ws : Eta_http.Ws.Client.t }
- lib/ai/openai/realtime.ml:293:  Eta_http.Core.Header.unsafe_of_list
- lib/ai/openai/realtime.ml:294:    (("Authorization", "Bearer " ^ Eta_redacted.value api_key)
- lib/ai/openai/realtime.ml:300:  Eta_http.Ws.Client.connect ~headers:(websocket_headers ?safety_identifier api_key)
- lib/ai/openai/realtime.ml:308:      Eta_http.Ws.Client.send_text t.ws raw
- lib/ai/openai/realtime.ml:312:  Eta_http.Ws.Client.incoming t.ws
- lib/ai/openai/realtime.ml:319:let close t = Eta_http.Ws.Client.close t.ws
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
- lib/ai/openai/realtime.mli:74:type realtime_error = [ Eta_http.Ws.Client.ws_error | `Encode of string ]
- lib/ai/openai/realtime.mli:76:val client_event_json : client_event -> (Eta_ai.Json.t, realtime_error) result
- lib/ai/openai/realtime.mli:77:val client_event_to_string : client_event -> (Eta_ai.raw_json, realtime_error) result
- lib/ai/openai/realtime.mli:78:val decode_server_event : Eta_ai.raw_json -> server_event
- lib/ai/openai/realtime.mli:85:  sw:Eio.Switch.t ->
- lib/ai/openai/realtime.mli:86:  net:_ Eio.Net.t ->
- lib/ai/openai/realtime.mli:87:  api_key:Eta_ai.api_key ->
- lib/ai/openai/realtime.mli:90:  (t, Eta_http.Ws.Client.ws_error) Eta.Effect.t
- lib/ai/openai/realtime.mli:92:val send_event : t -> client_event -> (unit, realtime_error) Eta.Effect.t
- lib/ai/openai/realtime.mli:93:val events : t -> (server_event, Eta_http.Ws.Client.ws_error) Eta_stream.Stream.t
- lib/ai/openai/realtime.mli:94:val close : t -> (unit, Eta_http.Ws.Client.ws_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:9:  schema : Eta_ai.Json.t;
- lib/ai/openai/eta_ai_openai.mli:18:  schema_json:Eta_ai.raw_json ->
- lib/ai/openai/eta_ai_openai.mli:20:  (structured_output, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:22:val provider : ?base_url:string -> unit -> Eta_ai.provider
- lib/ai/openai/eta_ai_openai.mli:26:val chat_completions_provider : ?base_url:string -> unit -> Eta_ai.provider
- lib/ai/openai/eta_ai_openai.mli:30:val responses_provider : ?base_url:string -> unit -> Eta_ai.provider
- lib/ai/openai/eta_ai_openai.mli:35:  include Eta_ai.Provider.Chat
- lib/ai/openai/eta_ai_openai.mli:39:    ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:40:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:41:    Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:42:    (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:46:    ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:47:    Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:48:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:49:    Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:50:    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:54:    ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:55:    Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:56:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:57:    Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:58:    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:61:module Embeddings : Eta_ai.Provider.Embeddings
- lib/ai/openai/eta_ai_openai.mli:62:module Images : Eta_ai.Provider.Images
- lib/ai/openai/eta_ai_openai.mli:63:module Speech : Eta_ai.Provider.Speech
- lib/ai/openai/eta_ai_openai.mli:64:module Transcriptions : Eta_ai.Provider.Transcriptions
- lib/ai/openai/eta_ai_openai.mli:68:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:69:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:73:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:74:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:76:val decode_chat : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:77:val decode_responses : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:79:  Eta_ai.Embedding.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:81:  Eta_ai.raw_json -> (Eta_ai.Embedding.response, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:83:  Eta_ai.Image.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:85:  Eta_ai.raw_json -> (Eta_ai.Image.response, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:87:  Eta_ai.Speech.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:89:  Eta_ai.raw_json -> (Eta_ai.Transcription.response, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:91:  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:93:  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error
- lib/ai/openai/eta_ai_openai.mli:99:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:100:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:101:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:102:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:106:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:107:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:108:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:109:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:112:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:113:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:114:  Eta_ai.Embedding.request ->
- lib/ai/openai/eta_ai_openai.mli:115:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:118:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:119:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:120:  Eta_ai.Image.request ->
- lib/ai/openai/eta_ai_openai.mli:121:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:124:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:125:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:126:  Eta_ai.Speech.request ->
- lib/ai/openai/eta_ai_openai.mli:127:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:130:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:131:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:132:  Eta_ai.Transcription.request ->
- lib/ai/openai/eta_ai_openai.mli:133:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openai/eta_ai_openai.mli:137:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:138:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:139:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:140:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:141:  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:145:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:146:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:147:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:148:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:149:  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:152:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:153:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:154:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:155:  Eta_ai.Embedding.request ->
- lib/ai/openai/eta_ai_openai.mli:156:  (Eta_ai.Embedding.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:159:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:160:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:161:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:162:  Eta_ai.Image.request ->
- lib/ai/openai/eta_ai_openai.mli:163:  (Eta_ai.Image.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:166:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:167:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:168:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:169:  Eta_ai.Speech.request ->
- lib/ai/openai/eta_ai_openai.mli:170:  (Eta_ai.Speech.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:173:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:174:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:175:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:176:  Eta_ai.Transcription.request ->
- lib/ai/openai/eta_ai_openai.mli:177:  (Eta_ai.Transcription.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:181:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:182:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:183:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:184:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:185:  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:189:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:190:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:191:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:192:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:193:  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
<!-- END DEP_MATCHES -->
