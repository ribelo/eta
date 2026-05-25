# Dependency Usage Audit

Run: bash packages/eta-ai-anthropic/audit/run.sh
Last updated: 2026-05-24T08:46:44Z
Current sites: 35

Allowed production dependencies for eta-ai-anthropic:

- eta
- eta-ai
- eta-redacted
- eta-http

The package must not depend on Anthropic SDKs, OpenAI SDKs, tokenizer
libraries, or provider-specific generated clients. Yojson is allowed for
structured JSON.

Search:

    rg -n -t ocaml 'Ai\.|Redacted\.|Http\.|Eta\.(Effect|Redacted|Runtime)|Eio\.|Openai|Anthropic|Tiktoken' packages/eta-ai-anthropic

| Site | Dependency | What | Replaceable? | Replacement cost |
| --- | --- | --- | --- | --- |
| eta_ai_anthropic.ml / eta_ai_anthropic.mli | eta-ai | Public provider vocabulary, effects, redacted API keys, and telemetry wrappers. | structural | high; this is the provider package contract. |
| eta_ai_anthropic.ml | eta-redacted | Extract API key value only at the x-api-key header boundary. | structural | low; required by provider auth. |
| eta_ai_anthropic.ml / eta_ai_anthropic.mli | eta-http | Build and submit HTTP requests through eta-http. | structural | high; AP2 must dogfood eta-http. |
| test/test_eta_ai_anthropic.ml | eta / eta-http | Run provider effects against fixture-backed eta-http clients. | replaceable | low; test harness only. |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
- packages/eta-ai-anthropic/test/test_eta_ai_anthropic.ml:3:module E = Eta.Effect
- packages/eta-ai-anthropic/test/test_eta_ai_anthropic.ml:78:  Eio.Switch.run @@ fun sw ->
- packages/eta-ai-anthropic/test/test_eta_ai_anthropic.ml:79:  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
- packages/eta-ai-anthropic/test/test_eta_ai_anthropic.ml:84:  Eio.Switch.run @@ fun sw ->
- packages/eta-ai-anthropic/test/test_eta_ai_anthropic.ml:87:    Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
- packages/eta-ai-anthropic/test/test_eta_ai_anthropic.ml:93:  match Eta.Runtime.run rt effect with
- packages/eta-ai-anthropic/test/test_eta_ai_anthropic.ml:342:    Eta.Runtime.run rt
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:1:(** Anthropic provider package for eta-ai.
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:3:    This package owns Anthropic-specific request encoding, response decoding,
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:13:    [beta_header] is added as [Anthropic-Beta]. When [cache_system] is true,
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:14:    system text is encoded as an Anthropic text block with ephemeral
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:25:  Ai.provider
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:31:  Ai.chat_request ->
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:32:  (Ai.raw_json, Ai.ai_error) result
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:34:val decode_message : Ai.raw_json -> (Ai.response, Ai.ai_error) result
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:36:  Ai.sse_event -> (Ai.stream_event list, Ai.ai_error) result
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:38:  status:int -> headers:Ai.headers -> Ai.raw_json -> Ai.ai_error
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:42:  ?provider:Ai.provider ->
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:43:  api_key:Ai.api_key ->
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:44:  Ai.chat_request ->
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:45:  (Http.Request.t, Ai.ai_error) result
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:49:  ?provider:Ai.provider ->
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:50:  Http.Client.t ->
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:51:  api_key:Ai.api_key ->
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:52:  Ai.chat_request ->
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:53:  (Ai.response, Ai.ai_error) Eta.Effect.t
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:57:  ?provider:Ai.provider ->
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:58:  Http.Client.t ->
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:59:  api_key:Ai.api_key ->
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:60:  Ai.chat_request ->
- packages/eta-ai-anthropic/eta_ai_anthropic.mli:61:  (Ai.stream, Ai.ai_error) Eta.Effect.t
- packages/eta-ai-anthropic/eta_ai_anthropic.ml:2:module E = Eta.Effect
- packages/eta-ai-anthropic/eta_ai_anthropic.ml:691:    | headers -> [ ("Anthropic-Beta", String.concat "," headers) ]
- packages/eta-ai-anthropic/eta_ai_anthropic.ml:695:       ("x-api-key", Redacted.value api_key);
- packages/eta-ai-anthropic/eta_ai_anthropic.ml:731:      |> H.Core.Header.add "Anthropic-Beta" value
<!-- END DEP_MATCHES -->
