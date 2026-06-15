# Dependency Usage Audit

Run: bash lib/ai/openrouter/audit/run.sh
Last updated: 2026-06-15T22:49:45Z
Current sites: 152

Allowed production dependencies for eta-ai-openrouter:

- eta
- eta-ai
- eta-redacted
- eta-http

The package must not depend on OpenAI SDKs, Anthropic SDKs, OpenRouter SDKs,
tokenizer libraries, provider-specific generated clients, or sibling provider
packages. Yojson is allowed for structured JSON.

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
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:2:  Eta_ai.Json.to_string
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:3:    (Eta_ai.Json.object_
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:5:         ("type", Some (Eta_ai.Json.string "object"));
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:8:             (Eta_ai.Json.object_
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:12:                      (Eta_ai.Json.object_
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:13:                         [ ("type", Some (Eta_ai.Json.string "string")) ]) );
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:22:  Eta_ai.make_tool ~name:"weather" ~description:"Get current weather"
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:26:let request : Eta_ai.chat_request =
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:74:                 ~api_key:(Eta_ai.api_key "sk-bench") request)));
- lib/ai/openrouter/eta_ai_openrouter.mli:40:  (routing, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:50:  (reasoning, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:55:  ?extra_headers:Eta_ai.headers ->
- lib/ai/openrouter/eta_ai_openrouter.mli:57:  Eta_ai.provider
- lib/ai/openrouter/eta_ai_openrouter.mli:63:  schema : Eta_ai.Json.t;
- lib/ai/openrouter/eta_ai_openrouter.mli:70:  schema_json:Eta_ai.raw_json ->
- lib/ai/openrouter/eta_ai_openrouter.mli:72:  (structured_output, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:75:  include Eta_ai.Provider.Chat
- lib/ai/openrouter/eta_ai_openrouter.mli:81:    Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:82:    (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:88:    ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:89:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:90:    Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:91:    (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:97:    ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:98:    Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:99:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:100:    Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:101:    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:107:    ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:108:    Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:109:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:110:    Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:111:    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:115:  include Eta_ai.Provider.Embeddings
- lib/ai/openrouter/eta_ai_openrouter.mli:120:    Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:121:    (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:126:    ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:127:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:128:    Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:129:    (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:134:    ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:135:    Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:136:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:137:    Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:138:      (Eta_ai.Embedding.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:141:module Speech : Eta_ai.Provider.Speech
- lib/ai/openrouter/eta_ai_openrouter.mli:142:module Images : Eta_ai.Provider.Images
- lib/ai/openrouter/eta_ai_openrouter.mli:143:module Transcriptions : Eta_ai.Provider.Transcriptions
- lib/ai/openrouter/eta_ai_openrouter.mli:144:module Rerank : Eta_ai.Provider.Rerank
- lib/ai/openrouter/eta_ai_openrouter.mli:145:module Video : Eta_ai.Provider.Video
- lib/ai/openrouter/eta_ai_openrouter.mli:151:  Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:152:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:156:  Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:160:  Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:161:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:165:  Eta_ai.raw_json -> (Eta_ai.Embedding.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:167:  Eta_ai.Speech.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:169:  Eta_ai.Image.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:171:  Eta_ai.raw_json -> (Eta_ai.Image.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:173:  Eta_ai.Transcription.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:175:  Eta_ai.raw_json -> (Eta_ai.Transcription.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:177:  Eta_ai.Rerank.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:179:  Eta_ai.raw_json -> (Eta_ai.Rerank.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:181:  Eta_ai.Video.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:183:  Eta_ai.raw_json -> (Eta_ai.Video.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:185:  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:187:  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error
- lib/ai/openrouter/eta_ai_openrouter.mli:193:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:194:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:195:  Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:196:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:201:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:202:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:203:  Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:204:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:207:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:208:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:209:  Eta_ai.Speech.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:210:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:213:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:214:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:215:  Eta_ai.Image.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:216:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:219:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:220:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:221:  Eta_ai.Transcription.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:222:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:225:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:226:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:227:  Eta_ai.Rerank.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:228:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:231:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:232:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:233:  Eta_ai.Video.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:234:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:237:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:238:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:241:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:244:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:245:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:246:  Eta_ai.Video.content_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:247:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:253:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:254:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:255:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:256:  Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:257:  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:262:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:263:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:264:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:265:  Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:266:  (Eta_ai.Embedding.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:269:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:270:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:271:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:272:  Eta_ai.Speech.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:273:  (Eta_ai.Speech.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:276:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:277:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:278:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:279:  Eta_ai.Image.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:280:  (Eta_ai.Image.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:283:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:284:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:285:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:286:  Eta_ai.Transcription.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:287:  (Eta_ai.Transcription.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:290:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:291:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:292:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:293:  Eta_ai.Rerank.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:294:  (Eta_ai.Rerank.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:297:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:298:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:299:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:300:  Eta_ai.Video.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:301:  (Eta_ai.Video.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:304:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:305:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:306:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:308:  (Eta_ai.Video.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:311:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:312:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:313:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:314:  Eta_ai.Video.content_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:315:  (Eta_ai.Video.content, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:321:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:322:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:323:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:324:  Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:325:  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/common.ml:204:       ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
<!-- END DEP_MATCHES -->
