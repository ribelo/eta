# Dependency Usage Audit

Run: bash lib/ai/openrouter/audit/run.sh
Current sites: 165

Allowed production dependencies for eta-ai-openrouter:

- eta
- eta-ai
- eta-redacted
- eta-http

The package must not depend on OpenAI SDKs, Anthropic SDKs, OpenRouter SDKs,
tokenizer libraries, provider-specific generated clients, sibling provider
packages, `eta_http_eio`, `eta_http_js`, Eio, or js_of_ocaml. Yojson is
allowed for structured JSON.

Search:

    rg -n -t ocaml 'Eta_ai\.|Eta_ai_openai\.|Eta_redacted\.|Eta_http\.|Eta\.(Effect|Eta_redacted|Runtime)|Eio\.|Openai|Anthropic|Tiktoken' lib/ai/openrouter

The search includes Eta_ai_openai to catch forbidden cross-provider usage.

| Site | Dependency | What | Replaceable? | Replacement cost |
| --- | --- | --- | --- | --- |
| eta_ai_openrouter.ml / eta_ai_openrouter.mli | eta-ai | Public provider vocabulary, effects, redacted API keys, and telemetry wrappers. | structural | high; this is the provider package contract. |
| eta_ai_openrouter.ml | eta-redacted | Extract API key value only at the HTTP Authorization header boundary. | structural | low; required by provider auth. |
| eta_ai_openrouter.ml / eta_ai_openrouter.mli | local codec | Responses-style request, response, SSE, structured-output, routing, and OpenRouter error mapping through Eta_ai.Json. | structural | medium; required by the provider dependency policy. |
| eta_ai_openrouter.ml / eta_ai_openrouter.mli | eta-http | Public request/response runner type. | structural | high; AP4 must dogfood eta-http directly. |
| bench/bench_ai_openrouter.ml | eta-ai | Build representative provider requests for package benchmarks. | replaceable | low; benchmark harness only. |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:4:let request : Eta_ai.tool Eta_ai.Responses.request =
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:7:    input = Eta_ai.Responses.Messages [ User [ Text "weather in Warsaw" ] ];
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:58:                 ~api_key:(Eta_ai.api_key "sk-bench") request)));
- lib/ai/openrouter/common.ml:266:       ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
- lib/ai/openrouter/eta_ai_openrouter.ml:215:  | Stdlib.Error error -> Eta.Effect.fail error
- lib/ai/openrouter/eta_ai_openrouter.mli:36:  (routing, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:41:val reasoning : ?effort:string -> unit -> (reasoning, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:48:type credential = Eta_ai.api_key
- lib/ai/openrouter/eta_ai_openrouter.mli:54:  ?extra_headers:Eta_ai.headers ->
- lib/ai/openrouter/eta_ai_openrouter.mli:56:  Eta_ai.headers
- lib/ai/openrouter/eta_ai_openrouter.mli:61:  ?extra_headers:Eta_ai.headers ->
- lib/ai/openrouter/eta_ai_openrouter.mli:63:  Eta_ai.provider
- lib/ai/openrouter/eta_ai_openrouter.mli:70:  ?extra_headers:Eta_ai.headers ->
- lib/ai/openrouter/eta_ai_openrouter.mli:72:  Eta_ai.tool Eta_ai.responses_provider
- lib/ai/openrouter/eta_ai_openrouter.mli:75:  include Eta_ai.Provider.Chat
- lib/ai/openrouter/eta_ai_openrouter.mli:80:    Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:81:    (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:86:    ?provider:Eta_ai.tool Eta_ai.responses_provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:87:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:88:    Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:89:    (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:94:    ?provider:Eta_ai.tool Eta_ai.responses_provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:95:    Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:96:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:97:    Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:98:    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:103:    ?provider:Eta_ai.tool Eta_ai.responses_provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:104:    Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:105:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:106:    Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:107:    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:111:  include Eta_ai.Provider.Embeddings
- lib/ai/openrouter/eta_ai_openrouter.mli:116:    Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:117:    (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:122:    ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:123:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:124:    Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:125:    (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:130:    ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:131:    Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:132:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:133:    Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:134:    (Eta_ai.Embedding.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:137:module Images : Eta_ai.Provider.Images
- lib/ai/openrouter/eta_ai_openrouter.mli:142:      model : Eta_ai.model;
- lib/ai/openrouter/eta_ai_openrouter.mli:143:      file : Eta_ai.Audio.upload;
- lib/ai/openrouter/eta_ai_openrouter.mli:153:      usage : Eta_ai.usage option;
- lib/ai/openrouter/eta_ai_openrouter.mli:154:      raw : Eta_ai.raw_json option;
- lib/ai/openrouter/eta_ai_openrouter.mli:158:      model : Eta_ai.model;
- lib/ai/openrouter/eta_ai_openrouter.mli:165:      Eta_ai.Audio.Speech_to_text.Provider
- lib/ai/openrouter/eta_ai_openrouter.mli:168:         and type error := Eta_ai.ai_error
- lib/ai/openrouter/eta_ai_openrouter.mli:172:    val encode : request -> (Eta_ai.raw_json, Eta_ai.ai_error) Stdlib.result
- lib/ai/openrouter/eta_ai_openrouter.mli:173:    val decode : Eta_ai.raw_json -> (result, Eta_ai.ai_error) Stdlib.result
- lib/ai/openrouter/eta_ai_openrouter.mli:176:      ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:177:      api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:179:      (Eta_http.Request.t, Eta_ai.ai_error) Stdlib.result
- lib/ai/openrouter/eta_ai_openrouter.mli:182:      ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:183:      Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:184:      api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:186:      (result, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:191:      model : Eta_ai.model;
- lib/ai/openrouter/eta_ai_openrouter.mli:197:      extra : (string * Eta_ai.Json.t) list;
- lib/ai/openrouter/eta_ai_openrouter.mli:200:    type result = Eta_ai.Audio.Text_to_speech.result = {
- lib/ai/openrouter/eta_ai_openrouter.mli:206:      model : Eta_ai.model;
- lib/ai/openrouter/eta_ai_openrouter.mli:207:      extra : (string * Eta_ai.Json.t) list;
- lib/ai/openrouter/eta_ai_openrouter.mli:213:      Eta_ai.Audio.Text_to_speech.Provider
- lib/ai/openrouter/eta_ai_openrouter.mli:216:         and type error := Eta_ai.ai_error
- lib/ai/openrouter/eta_ai_openrouter.mli:220:    val encode : request -> (Eta_ai.raw_json, Eta_ai.ai_error) Stdlib.result
- lib/ai/openrouter/eta_ai_openrouter.mli:223:      ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:224:      api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:226:      (Eta_http.Request.t, Eta_ai.ai_error) Stdlib.result
- lib/ai/openrouter/eta_ai_openrouter.mli:229:      ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:230:      Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:231:      api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:233:      (result, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:237:module Rerank : Eta_ai.Provider.Rerank
- lib/ai/openrouter/eta_ai_openrouter.mli:238:module Video : Eta_ai.Provider.Video
- lib/ai/openrouter/eta_ai_openrouter.mli:243:  Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:244:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:248:  Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:253:  Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:254:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:258:  Eta_ai.raw_json -> (Eta_ai.Embedding.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:261:  Eta_ai.Image.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:264:  Eta_ai.raw_json -> (Eta_ai.Image.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:267:  Eta_ai.Rerank.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:270:  Eta_ai.raw_json -> (Eta_ai.Rerank.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:273:  Eta_ai.Video.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:276:  Eta_ai.raw_json -> (Eta_ai.Video.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:279:  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:282:  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error
- lib/ai/openrouter/eta_ai_openrouter.mli:307:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:308:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:310:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:312:val decode_models : Eta_ai.raw_json -> (model_info list, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:315:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:316:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:317:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:318:  (model_info list, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:323:  ?provider:Eta_ai.tool Eta_ai.responses_provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:324:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:325:  Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:326:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:331:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:332:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:333:  Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:334:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:337:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:338:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:339:  Eta_ai.Image.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:340:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:343:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:344:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:345:  Eta_ai.Rerank.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:346:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:349:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:350:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:351:  Eta_ai.Video.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:352:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:355:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:356:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:359:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:362:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:363:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:364:  Eta_ai.Video.content_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:365:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:370:  ?provider:Eta_ai.tool Eta_ai.responses_provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:371:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:372:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:373:  Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:374:  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:379:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:380:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:381:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:382:  Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:383:  (Eta_ai.Embedding.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:386:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:387:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:388:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:389:  Eta_ai.Image.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:390:  (Eta_ai.Image.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:393:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:394:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:395:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:396:  Eta_ai.Rerank.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:397:  (Eta_ai.Rerank.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:400:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:401:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:402:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:403:  Eta_ai.Video.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:404:  (Eta_ai.Video.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:407:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:408:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:409:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:411:  (Eta_ai.Video.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:414:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:415:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:416:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:417:  Eta_ai.Video.content_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:418:  (Eta_ai.Video.content, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:423:  ?provider:Eta_ai.tool Eta_ai.responses_provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:424:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:425:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:426:  Eta_ai.tool Eta_ai.Responses.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:427:  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
<!-- END DEP_MATCHES -->
