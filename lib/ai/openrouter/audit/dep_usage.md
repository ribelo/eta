# Dependency Usage Audit

Run: bash lib/ai/openrouter/audit/run.sh
Last updated: 2026-05-28T19:07:34Z
Current sites: 163

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
| test/test_eta_ai_openrouter.ml | eta / eta-http | Run provider effects against fixture-backed eta-http clients. | replaceable | low; test harness only. |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:9:  Eta_ai.make_tool ~name:"weather" ~description:"Get current weather"
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:13:let request : Eta_ai.chat_request =
- lib/ai/openrouter/bench/bench_ai_openrouter.ml:61:                 ~api_key:(Eta_ai.api_key "sk-bench") request)));
- lib/ai/openrouter/eta_ai_openrouter.ml:3:module E = Eta.Effect
- lib/ai/openrouter/eta_ai_openrouter.ml:328:       ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
- lib/ai/openrouter/eta_ai_openrouter.mli:38:  (routing, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:43:  ?extra_headers:Eta_ai.headers ->
- lib/ai/openrouter/eta_ai_openrouter.mli:45:  Eta_ai.provider
- lib/ai/openrouter/eta_ai_openrouter.mli:51:  schema : Eta_ai.Json.t;
- lib/ai/openrouter/eta_ai_openrouter.mli:58:  schema_json:Eta_ai.raw_json ->
- lib/ai/openrouter/eta_ai_openrouter.mli:60:  (structured_output, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:63:  include Eta_ai.Provider.Chat
- lib/ai/openrouter/eta_ai_openrouter.mli:68:    Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:69:    (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:74:    ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:75:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:76:    Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:77:    (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:82:    ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:83:    Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:84:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:85:    Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:86:    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:91:    ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:92:    Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:93:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:94:    Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:95:    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:99:  include Eta_ai.Provider.Embeddings
- lib/ai/openrouter/eta_ai_openrouter.mli:104:    Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:105:    (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:110:    ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:111:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:112:    Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:113:    (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:118:    ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:119:    Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:120:    api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:121:    Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:122:      (Eta_ai.Embedding.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:125:module Speech : Eta_ai.Provider.Speech
- lib/ai/openrouter/eta_ai_openrouter.mli:126:module Images : Eta_ai.Provider.Images
- lib/ai/openrouter/eta_ai_openrouter.mli:127:module Transcriptions : Eta_ai.Provider.Transcriptions
- lib/ai/openrouter/eta_ai_openrouter.mli:128:module Rerank : Eta_ai.Provider.Rerank
- lib/ai/openrouter/eta_ai_openrouter.mli:129:module Video : Eta_ai.Provider.Video
- lib/ai/openrouter/eta_ai_openrouter.mli:134:  Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:135:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:141:  Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:142:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:144:val decode_chat : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:146:  Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:150:  Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:151:  (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:155:  Eta_ai.raw_json -> (Eta_ai.Embedding.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:157:  Eta_ai.Speech.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:159:  Eta_ai.Image.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:161:  Eta_ai.raw_json -> (Eta_ai.Image.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:163:  Eta_ai.Transcription.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:165:  Eta_ai.raw_json -> (Eta_ai.Transcription.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:167:  Eta_ai.Rerank.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:169:  Eta_ai.raw_json -> (Eta_ai.Rerank.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:171:  Eta_ai.Video.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:173:  Eta_ai.raw_json -> (Eta_ai.Video.response, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:175:  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:177:  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error
- lib/ai/openrouter/eta_ai_openrouter.mli:182:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:183:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:184:  Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:185:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:190:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:191:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:192:  Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:193:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:199:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:200:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:201:  Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:202:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:205:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:206:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:207:  Eta_ai.Speech.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:208:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:211:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:212:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:213:  Eta_ai.Image.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:214:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:217:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:218:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:219:  Eta_ai.Transcription.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:220:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:223:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:224:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:225:  Eta_ai.Rerank.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:226:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:229:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:230:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:231:  Eta_ai.Video.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:232:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:235:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:236:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:239:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:242:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:243:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:244:  Eta_ai.Video.content_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:245:  (Eta_http.Request.t, Eta_ai.ai_error) result
- lib/ai/openrouter/eta_ai_openrouter.mli:250:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:251:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:252:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:253:  Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:254:  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:259:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:260:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:261:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:262:  Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:263:  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:269:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:270:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:271:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:272:  Eta_ai.Embedding.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:273:  (Eta_ai.Embedding.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:276:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:277:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:278:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:279:  Eta_ai.Speech.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:280:  (Eta_ai.Speech.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:283:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:284:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:285:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:286:  Eta_ai.Image.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:287:  (Eta_ai.Image.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:290:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:291:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:292:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:293:  Eta_ai.Transcription.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:294:  (Eta_ai.Transcription.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:297:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:298:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:299:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:300:  Eta_ai.Rerank.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:301:  (Eta_ai.Rerank.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:304:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:305:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:306:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:307:  Eta_ai.Video.request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:308:  (Eta_ai.Video.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:311:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:312:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:313:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:315:  (Eta_ai.Video.response, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:318:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:319:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:320:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:321:  Eta_ai.Video.content_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:322:  (Eta_ai.Video.content, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:327:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:328:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:329:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:330:  Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:331:  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
- lib/ai/openrouter/eta_ai_openrouter.mli:336:  ?provider:Eta_ai.provider ->
- lib/ai/openrouter/eta_ai_openrouter.mli:337:  Eta_http.Client.t ->
- lib/ai/openrouter/eta_ai_openrouter.mli:338:  api_key:Eta_ai.api_key ->
- lib/ai/openrouter/eta_ai_openrouter.mli:339:  Eta_ai.chat_request ->
- lib/ai/openrouter/eta_ai_openrouter.mli:340:  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
<!-- END DEP_MATCHES -->
