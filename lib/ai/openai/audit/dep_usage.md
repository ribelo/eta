# Dependency Usage Audit

Run: bash lib/ai/openai/audit/run.sh
Current sites: 226

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
- lib/ai/openai/bench/bench_ai_openai.ml:5:let request : Eta_ai.chat_request =
- lib/ai/openai/bench/bench_ai_openai.ml:17:let responses_request : Eta_ai.tool Eta_ai.Responses.request =
- lib/ai/openai/bench/bench_ai_openai.ml:20:    input = Eta_ai.Responses.Messages request.prompt;
- lib/ai/openai/bench/bench_ai_openai.ml:68:                 ~api_key:(Eta_ai.api_key "sk-bench") responses_request)));
- lib/ai/openai/common.ml:7:module E = Eta.Effect
- lib/ai/openai/common.ml:8:module Error = Openai_error
- lib/ai/openai/common.ml:159:  Eta_http.Core.Header.unsafe_of_list
- lib/ai/openai/common.ml:161:      ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
- lib/ai/openai/eta_ai_openai.ml:6:module Error = Openai_error
- lib/ai/openai/eta_ai_openai.mli:10:module Error = Openai_error
- lib/ai/openai/eta_ai_openai.mli:17:  schema : Eta_ai.Json.t;
- lib/ai/openai/eta_ai_openai.mli:26:  schema_json:Eta_ai.raw_json ->
- lib/ai/openai/eta_ai_openai.mli:34:type credential = Eta_ai.api_key
- lib/ai/openai/eta_ai_openai.mli:36:val authorization_headers : credential -> Eta_ai.headers
- lib/ai/openai/eta_ai_openai.mli:39:val provider : ?base_url:string -> unit -> Eta_ai.provider
- lib/ai/openai/eta_ai_openai.mli:43:    The shared [Eta_ai.provider] record remains neutral ([Eta_ai.ai_error]) so
- lib/ai/openai/eta_ai_openai.mli:49:val chat_completions_provider : ?base_url:string -> unit -> Eta_ai.provider
- lib/ai/openai/eta_ai_openai.mli:54:  ?base_url:string -> unit -> Eta_ai.tool Eta_ai.responses_provider
- lib/ai/openai/eta_ai_openai.mli:60:    provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:61:    Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:62:    (Eta_ai.raw_json, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:65:    provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:66:    Eta_ai.raw_json ->
- lib/ai/openai/eta_ai_openai.mli:67:    (Eta_ai.response, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:70:    provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:71:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:72:    Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:73:    (Eta_http.Request.t, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:76:    provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:77:    Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:78:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:79:    Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:80:    (Eta_ai.response, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:83:    provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:84:    Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:85:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:86:    Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:87:    (stream, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:90:    ?provider:Eta_ai.tool Eta_ai.responses_provider ->
- lib/ai/openai/eta_ai_openai.mli:91:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:92:    Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openai/eta_ai_openai.mli:93:    (Eta_http.Request.t, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:96:    ?provider:Eta_ai.tool Eta_ai.responses_provider ->
- lib/ai/openai/eta_ai_openai.mli:97:    Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:98:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:99:    Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openai/eta_ai_openai.mli:100:    (Eta_ai.response, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:103:    ?provider:Eta_ai.tool Eta_ai.responses_provider ->
- lib/ai/openai/eta_ai_openai.mli:104:    Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:105:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:106:    Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openai/eta_ai_openai.mli:107:    (stream, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:112:    provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:113:    Eta_ai.Embedding.request ->
- lib/ai/openai/eta_ai_openai.mli:114:    (Eta_ai.raw_json, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:117:    provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:118:    Eta_ai.raw_json ->
- lib/ai/openai/eta_ai_openai.mli:119:    (Eta_ai.Embedding.response, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:122:    provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:123:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:124:    Eta_ai.Embedding.request ->
- lib/ai/openai/eta_ai_openai.mli:125:    (Eta_http.Request.t, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:128:    provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:129:    Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:130:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:131:    Eta_ai.Embedding.request ->
- lib/ai/openai/eta_ai_openai.mli:132:    (Eta_ai.Embedding.response, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:137:    provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:138:    Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:139:    api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:140:    Eta_ai.Image.request ->
- lib/ai/openai/eta_ai_openai.mli:141:    (Eta_ai.Image.response, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:151:      model : Eta_ai.model;
- lib/ai/openai/eta_ai_openai.mli:152:      file : Eta_ai.Audio.upload;
- lib/ai/openai/eta_ai_openai.mli:164:      usage : Eta_ai.usage option;
- lib/ai/openai/eta_ai_openai.mli:165:      raw : Eta_ai.raw_json option;
- lib/ai/openai/eta_ai_openai.mli:169:      model : Eta_ai.model;
- lib/ai/openai/eta_ai_openai.mli:179:      Eta_ai.Audio.Speech_to_text.Provider
- lib/ai/openai/eta_ai_openai.mli:186:    val decode_response : Eta_ai.raw_json -> (result, Error.t) Stdlib.result
- lib/ai/openai/eta_ai_openai.mli:189:      ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:190:      api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:192:      (Eta_http.Request.t, Error.t) Stdlib.result
- lib/ai/openai/eta_ai_openai.mli:195:      ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:196:      Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:197:      api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:199:      (result, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:204:      model : Eta_ai.model;
- lib/ai/openai/eta_ai_openai.mli:210:      extra : (string * Eta_ai.Json.t) list;
- lib/ai/openai/eta_ai_openai.mli:219:      model : Eta_ai.model;
- lib/ai/openai/eta_ai_openai.mli:221:      extra : (string * Eta_ai.Json.t) list;
- lib/ai/openai/eta_ai_openai.mli:227:      Eta_ai.Audio.Text_to_speech.Provider
- lib/ai/openai/eta_ai_openai.mli:234:    val encode : request -> (Eta_ai.raw_json, Error.t) Stdlib.result
- lib/ai/openai/eta_ai_openai.mli:237:      ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:238:      api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:240:      (Eta_http.Request.t, Error.t) Stdlib.result
- lib/ai/openai/eta_ai_openai.mli:243:      ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:244:      Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:245:      api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:247:      (result, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:255:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:256:  (Eta_ai.raw_json, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:259:  Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openai/eta_ai_openai.mli:260:  (Eta_ai.raw_json, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:262:val decode_chat : Eta_ai.raw_json -> (Eta_ai.response, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:263:val decode_responses : Eta_ai.raw_json -> (Eta_ai.response, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:265:  Eta_ai.Embedding.request -> (Eta_ai.raw_json, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:267:  Eta_ai.raw_json -> (Eta_ai.Embedding.response, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:269:  Eta_ai.Image.request -> (Eta_ai.raw_json, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:271:  Eta_ai.raw_json -> (Eta_ai.Image.response, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:273:  Eta_ai.sse_event -> (Eta_ai.stream_event list, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:275:  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Error.t
- lib/ai/openai/eta_ai_openai.mli:279:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:280:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:281:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:282:  (Eta_http.Request.t, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:285:  ?provider:Eta_ai.tool Eta_ai.responses_provider ->
- lib/ai/openai/eta_ai_openai.mli:286:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:287:  Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openai/eta_ai_openai.mli:288:  (Eta_http.Request.t, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:291:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:292:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:293:  Eta_ai.Embedding.request ->
- lib/ai/openai/eta_ai_openai.mli:294:  (Eta_http.Request.t, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:297:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:298:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:299:  Eta_ai.Image.request ->
- lib/ai/openai/eta_ai_openai.mli:300:  (Eta_http.Request.t, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:304:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:305:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:306:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:307:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:308:  (Eta_ai.response, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:311:  ?provider:Eta_ai.tool Eta_ai.responses_provider ->
- lib/ai/openai/eta_ai_openai.mli:312:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:313:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:314:  Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openai/eta_ai_openai.mli:315:  (Eta_ai.response, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:318:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:319:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:320:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:321:  Eta_ai.Embedding.request ->
- lib/ai/openai/eta_ai_openai.mli:322:  (Eta_ai.Embedding.response, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:325:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:326:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:327:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:328:  Eta_ai.Image.request ->
- lib/ai/openai/eta_ai_openai.mli:329:  (Eta_ai.Image.response, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:333:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:334:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:335:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:336:  Eta_ai.chat_request ->
- lib/ai/openai/eta_ai_openai.mli:337:  (stream, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:340:  ?provider:Eta_ai.tool Eta_ai.responses_provider ->
- lib/ai/openai/eta_ai_openai.mli:341:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:342:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:343:  Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openai/eta_ai_openai.mli:344:  (stream, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:346:val stream_of_body : Eta_ai.provider -> Eta_http.Body.Stream.t -> stream
- lib/ai/openai/eta_ai_openai.mli:350:  stream -> (Eta_ai.stream_event option, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:356:  stream -> (Eta_ai.stream_event list, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:360:val close_stream : stream -> (unit, Error.t) Eta.Effect.t
- lib/ai/openai/eta_ai_openai.mli:370:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:371:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:373:  (Eta_http.Request.t, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:375:val decode_models : Eta_ai.raw_json -> (model_info list, Error.t) result
- lib/ai/openai/eta_ai_openai.mli:378:  ?provider:Eta_ai.provider ->
- lib/ai/openai/eta_ai_openai.mli:379:  Eta_http.Client.t ->
- lib/ai/openai/eta_ai_openai.mli:380:  api_key:Eta_ai.api_key ->
- lib/ai/openai/eta_ai_openai.mli:381:  (model_info list, Error.t) Eta.Effect.t
- lib/ai/openai/openai_error.ml:14:  | Http of Eta_http.Error.t
- lib/ai/openai/openai_error.ml:222:  | Http error -> Format.pp_print_string fmt (Eta_http.Error.to_string error)
- lib/ai/openai/openai_error.mli:6:  param : Eta_ai.Json.t option;
- lib/ai/openai/openai_error.mli:7:  code : Eta_ai.Json.t option;
- lib/ai/openai/openai_error.mli:9:  raw : Eta_ai.Json.t;
- lib/ai/openai/openai_error.mli:11:  full : Eta_ai.Json.t;
- lib/ai/openai/openai_error.mli:15:  | Http of Eta_http.Error.t
- lib/ai/openai/openai_error.mli:17:  | Provider of provider_payload Eta_ai.Provider.Error.http_response
- lib/ai/openai/openai_error.mli:19:  | Unknown_response of unit Eta_ai.Provider.Error.http_response
- lib/ai/openai/openai_error.mli:25:      param : Eta_ai.Json.t option;
- lib/ai/openai/openai_error.mli:26:      code : Eta_ai.Json.t option;
- lib/ai/openai/openai_error.mli:27:      raw : Eta_ai.Json.t option;
- lib/ai/openai/openai_error.mli:28:      full : Eta_ai.Json.t option;
- lib/ai/openai/openai_error.mli:29:      raw_body : Eta_ai.raw_json option;
- lib/ai/openai/openai_error.mli:36:      raw_body : Eta_ai.raw_json option;
- lib/ai/openai/openai_error.mli:46:  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> t
- lib/ai/openai/openai_error.mli:51:  ?raw_body:Eta_ai.raw_json ->
- lib/ai/openai/openai_error.mli:60:val of_ai_error : Eta_ai.ai_error -> t
- lib/ai/openai/openai_error.mli:61:(** Map a codec/neutral [Eta_ai.ai_error] into this nominal channel without
- lib/ai/openai/openai_error.mli:69:val to_ai_error : t -> Eta_ai.ai_error
- lib/ai/openai/openai_error.mli:70:(** Total explicit projection into the neutral [Eta_ai.ai_error] vocabulary. *)
- lib/ai/openai/realtime.ml:2:module E = Eta.Effect
- lib/ai/openai/realtime.ml:3:module Error = Openai_error
- lib/ai/openai/realtime.ml:98:  Eta_http.Core.Header.unsafe_of_list
- lib/ai/openai/realtime.ml:100:      ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
- lib/ai/openai/realtime.ml:109:  Eta_http.Request.make ~headers:(auth_headers api_key)
- lib/ai/openai/realtime.ml:110:    ~body:(Eta_http.Request.Fixed [ Bytes.of_string body ])
- lib/ai/openai/realtime.ml:115:  Eta_http.Body.Stream.read_all body
- lib/ai/openai/realtime.ml:142:  Eta_http.request client request
- lib/ai/openai/realtime.ml:145:  |> E.bind (fun (response : Eta_http.Response.t) ->
- lib/ai/openai/realtime.ml:146:         read_response_body response.Eta_http.Response.body
- lib/ai/openai/realtime.mli:3:type error = Openai_error.t
- lib/ai/openai/realtime.mli:12:  input_audio_format : Eta_ai.audio_format option;
- lib/ai/openai/realtime.mli:13:  output_audio_format : Eta_ai.audio_format option;
- lib/ai/openai/realtime.mli:15:  turn_detection : Eta_ai.Json.t option;
- lib/ai/openai/realtime.mli:16:  tools : Eta_ai.Json.t option;
- lib/ai/openai/realtime.mli:25:  ?input_audio_format:Eta_ai.audio_format ->
- lib/ai/openai/realtime.mli:26:  ?output_audio_format:Eta_ai.audio_format ->
- lib/ai/openai/realtime.mli:28:  ?turn_detection:Eta_ai.Json.t ->
- lib/ai/openai/realtime.mli:29:  ?tools:Eta_ai.Json.t ->
- lib/ai/openai/realtime.mli:35:val session_json : session -> Eta_ai.Json.t
- lib/ai/openai/realtime.mli:36:val session_to_string : session -> Eta_ai.raw_json
- lib/ai/openai/realtime.mli:41:  raw : Eta_ai.raw_json option;
- lib/ai/openai/realtime.mli:45:  ?base_url:string -> api_key:Eta_ai.api_key -> session -> Eta_http.Request.t
- lib/ai/openai/realtime.mli:49:  Eta_http.Client.t ->
- lib/ai/openai/realtime.mli:50:  api_key:Eta_ai.api_key ->
- lib/ai/openai/realtime.mli:52:  (client_secret, error) Eta.Effect.t
- lib/ai/openai/realtime.mli:56:  | Input_audio_buffer_append of Eta_ai.audio
- lib/ai/openai/realtime.mli:59:  | Raw_client_event of Eta_ai.Json.t
- lib/ai/openai/realtime.mli:64:  raw : Eta_ai.raw_json option;
- lib/ai/openai/realtime.mli:68:  | Session_created of Eta_ai.raw_json option
- lib/ai/openai/realtime.mli:71:  | Response_done of Eta_ai.raw_json option
- lib/ai/openai/realtime.mli:74:  | Raw_server_event of { type_ : string option; raw : Eta_ai.raw_json }
- lib/ai/openai/realtime.mli:76:val client_event_json : client_event -> Eta_ai.Json.t
- lib/ai/openai/realtime.mli:77:val client_event_to_string : client_event -> Eta_ai.raw_json
- lib/ai/openai/realtime.mli:80:  Eta_ai.raw_json -> (server_event, error) result
- lib/ai/openai/realtime.mli:85:    Eta_ai.Realtime.Codec
<!-- END DEP_MATCHES -->
