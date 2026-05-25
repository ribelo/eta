# Dependency Usage Audit

Run: bash packages/eta-ai/audit/run.sh
Last updated: 2026-05-24T08:46:44Z
Current sites: 129

Every eta-ai call site for an allowed external dependency is listed here. The
catalog is not a gate; it is the truth-of-record.

Allowed production dependencies for eta-ai core:

- eta
- eta-redacted
- eta-stream
- eta-http
- yojson

Search:

    rg -n -t ocaml 'Redacted\.|Eta\.(Redacted|Effect|Tracer|Logger|Capabilities|Runtime)|Http\.|Stream\.|Eio\.|Tiktoken' packages/eta-ai

| Site | Dependency | What | Replaceable? | Replacement cost |
| --- | --- | --- | --- | --- |
| eta_ai.ml | eta-http | Preserve typed eta-http errors in Ai_error. | structural | low; could erase to string, but that loses retry/status details. |
| eta_ai.mli | eta-http | Expose typed eta-http errors in the public error vocabulary. | structural | low; public type can change before providers ship. |
| eta_ai.ml | eta-redacted | Use Redacted.t for API-key typed provider auth. | structural | low; public auth type can still change before provider packages ship. |
| eta_ai.mli | eta-redacted | Expose Redacted.t for API-key typed provider auth. | structural | low; aligns AC6 before provider auth becomes widely used. |
| eta_ai.ml / eta_ai.mli | eta / eta-http | AC3 pull stream uses Eta effects over eta-http body streams. | structural | medium; this is the current A2-approved streaming substrate. |
| eta_ai.ml / eta_ai.mli | eta / eta-http | AC5 GenAI telemetry wraps Eta effects, parses provider base URLs, and suppresses provider transport observability. | structural | medium; this is the common telemetry shape provider packages use. |
| eta_ai.ml / eta_ai.mli | eta-redacted | AC6 API keys use Redacted.t with the eta-ai API-key label. | structural | low; this is the required redaction boundary for provider keys. |
| test/test_eta_ai.ml | eta-redacted / eta-http | Prove provider auth builders can consume Redacted.t and produce eta-http headers. | replaceable | low; test-only fixture. |
| test/test_eta_ai.ml | Eio / eta / eta-http | Run eta-http body-stream, tracer, and logger effects under local Eta runtimes. | replaceable | low; eta-test could provide a shared runtime fixture. |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
- packages/eta-ai/eta_ai.ml:2:type headers = Http.Core.Header.t
- packages/eta-ai/eta_ai.ml:3:type api_key = string Redacted.t
- packages/eta-ai/eta_ai.ml:4:let api_key value = Redacted.make ~label:"api_key" value
- packages/eta-ai/eta_ai.ml:84:  | Http_error of Http.Error.t
- packages/eta-ai/eta_ai.ml:199:  Http.Request.make ~headers
- packages/eta-ai/eta_ai.ml:200:    ~body:(Http.Request.Fixed [ Bytes.of_string raw ])
- packages/eta-ai/eta_ai.ml:204:  Http.Body.Stream.read_all body
- packages/eta-ai/eta_ai.ml:205:  |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Http_error error))
- packages/eta-ai/eta_ai.ml:206:  |> Eta.Effect.map Bytes.to_string
- packages/eta-ai/eta_ai.ml:209:  | Stdlib.Ok value -> Eta.Effect.pure value
- packages/eta-ai/eta_ai.ml:210:  | Stdlib.Error error -> Eta.Effect.fail error
- packages/eta-ai/eta_ai.ml:213:  Http.request client request
- packages/eta-ai/eta_ai.ml:214:  |> Eta.Effect.suppress_observability
- packages/eta-ai/eta_ai.ml:215:  |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Http_error error))
- packages/eta-ai/eta_ai.ml:219:  |> Eta.Effect.bind (fun response ->
- packages/eta-ai/eta_ai.ml:221:           response.Http.Response.status >= 200
- packages/eta-ai/eta_ai.ml:225:           |> Eta.Effect.bind (fun raw ->
- packages/eta-ai/eta_ai.ml:229:           |> Eta.Effect.bind (fun raw ->
- packages/eta-ai/eta_ai.ml:230:                  Eta.Effect.fail
- packages/eta-ai/eta_ai.ml:236:  body : Http.Body.Stream.t;
- packages/eta-ai/eta_ai.ml:261:  |> Eta.Effect.bind (fun response ->
- packages/eta-ai/eta_ai.ml:263:           response.Http.Response.status >= 200
- packages/eta-ai/eta_ai.ml:265:         then Eta.Effect.pure (stream_of_body provider response.body)
- packages/eta-ai/eta_ai.ml:268:           |> Eta.Effect.bind (fun raw ->
- packages/eta-ai/eta_ai.ml:269:                  Eta.Effect.fail
- packages/eta-ai/eta_ai.ml:336:  if stream.released then Eta.Effect.unit
- packages/eta-ai/eta_ai.ml:339:    Http.Body.Stream.discard stream.body
- packages/eta-ai/eta_ai.ml:340:    |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Http_error error)))
- packages/eta-ai/eta_ai.ml:349:  close_stream stream |> Eta.Effect.bind (fun () -> Eta.Effect.fail error)
- packages/eta-ai/eta_ai.ml:363:    | [] -> Eta.Effect.pure (List.rev acc)
- packages/eta-ai/eta_ai.ml:375:      Eta.Effect.pure (Some event)
- packages/eta-ai/eta_ai.ml:376:  | [] when stream.eof -> Eta.Effect.pure None
- packages/eta-ai/eta_ai.ml:378:      Http.Body.Stream.read stream.body
- packages/eta-ai/eta_ai.ml:379:      |> Eta.Effect.catch (fun error ->
- packages/eta-ai/eta_ai.ml:381:      |> Eta.Effect.bind (function
- packages/eta-ai/eta_ai.ml:386:               |> Eta.Effect.bind (fun events ->
- packages/eta-ai/eta_ai.ml:389:                      |> Eta.Effect.bind (fun () -> read_stream_event stream))
- packages/eta-ai/eta_ai.ml:396:                 |> Eta.Effect.bind (fun events ->
- packages/eta-ai/eta_ai.ml:408:        close_stream stream |> Eta.Effect.bind (fun () ->
- packages/eta-ai/eta_ai.ml:409:            Eta.Effect.pure (List.rev acc))
- packages/eta-ai/eta_ai.ml:411:        read_stream_event stream |> Eta.Effect.bind (function
- packages/eta-ai/eta_ai.ml:412:          | None -> Eta.Effect.pure (List.rev acc)
- packages/eta-ai/eta_ai.ml:423:    (fun (key, value) acc -> Eta.Effect.annotate ~key ~value acc)
- packages/eta-ai/eta_ai.ml:466:  match Http.Core.Url.parse provider.base_url with
- packages/eta-ai/eta_ai.ml:469:        ("server.address", Http.Core.Url.host url);
- packages/eta-ai/eta_ai.ml:470:        ("server.port", string_of_int (Http.Core.Url.effective_port url));
- packages/eta-ai/eta_ai.ml:491:  | Http_error error -> Http.Error.to_string error
- packages/eta-ai/eta_ai.ml:500:  |> Eta.Effect.catch (fun error ->
- packages/eta-ai/eta_ai.ml:501:         Eta.Effect.fail error
- packages/eta-ai/eta_ai.ml:506:  |> Eta.Effect.named_kind ~error_renderer:ai_error_message ~kind name
- packages/eta-ai/eta_ai.ml:511:    |> Eta.Effect.bind (fun response ->
- packages/eta-ai/eta_ai.ml:512:           Eta.Effect.pure response |> annotate (response_attrs response))
- packages/eta-ai/eta_ai.ml:518:  with_span ~kind:Eta.Capabilities.Client
- packages/eta-ai/eta_ai.ml:530:  with_span ~kind:Eta.Capabilities.Client
- packages/eta-ai/eta_ai.ml:547:  with_span ~kind:Eta.Capabilities.Client
- packages/eta-ai/eta_ai.ml:560:  with_span ~kind:Eta.Capabilities.Internal
- packages/eta-ai/eta_ai.ml:565:  Eta.Effect.suppress_observability
- packages/eta-ai/eta_ai.mli:10:type headers = Http.Core.Header.t
- packages/eta-ai/eta_ai.mli:11:type api_key = string Redacted.t
- packages/eta-ai/eta_ai.mli:93:  | Http_error of Http.Error.t
- packages/eta-ai/eta_ai.mli:181:  provider -> api_key -> raw_json -> Http.Request.t
- packages/eta-ai/eta_ai.mli:186:  Http.Client.t ->
- packages/eta-ai/eta_ai.mli:187:  Http.Request.t ->
- packages/eta-ai/eta_ai.mli:188:  (response, ai_error) Eta.Effect.t
- packages/eta-ai/eta_ai.mli:199:  ?max_buffer_bytes:int -> provider -> Http.Body.Stream.t -> stream
- packages/eta-ai/eta_ai.mli:205:  Http.Client.t ->
- packages/eta-ai/eta_ai.mli:206:  Http.Request.t ->
- packages/eta-ai/eta_ai.mli:207:  (stream, ai_error) Eta.Effect.t
- packages/eta-ai/eta_ai.mli:211:val read_stream_event : stream -> (stream_event option, ai_error) Eta.Effect.t
- packages/eta-ai/eta_ai.mli:215:  ?max_events:int -> stream -> (stream_event list, ai_error) Eta.Effect.t
- packages/eta-ai/eta_ai.mli:219:val close_stream : stream -> (unit, ai_error) Eta.Effect.t
- packages/eta-ai/eta_ai.mli:225:  (response, ai_error) Eta.Effect.t ->
- packages/eta-ai/eta_ai.mli:226:  (response, ai_error) Eta.Effect.t
- packages/eta-ai/eta_ai.mli:234:  ('a, ai_error) Eta.Effect.t ->
- packages/eta-ai/eta_ai.mli:235:  ('a, ai_error) Eta.Effect.t
- packages/eta-ai/eta_ai.mli:242:  ('a, ai_error) Eta.Effect.t ->
- packages/eta-ai/eta_ai.mli:243:  ('a, ai_error) Eta.Effect.t
- packages/eta-ai/eta_ai.mli:250:  ('a, ai_error) Eta.Effect.t ->
- packages/eta-ai/eta_ai.mli:251:  ('a, ai_error) Eta.Effect.t
- packages/eta-ai/eta_ai.mli:256:  ('a, 'err) Eta.Effect.t -> ('a, 'err) Eta.Effect.t
- packages/eta-ai/test/test_eta_ai.ml:54:  let rendered = Format.asprintf "%a" Redacted.pp key in
- packages/eta-ai/test/test_eta_ai.ml:75:          Http.Core.Header.of_list
- packages/eta-ai/test/test_eta_ai.ml:77:              ("Authorization", "Bearer " ^ Redacted.value api_key);
- packages/eta-ai/test/test_eta_ai.ml:121:  let headers = provider.auth_headers (Redacted.make "sk-test") in
- packages/eta-ai/test/test_eta_ai.ml:125:    (Option.get (Http.Core.Header.get "authorization" headers));
- packages/eta-ai/test/test_eta_ai.ml:319:  Eio.Switch.run @@ fun sw ->
- packages/eta-ai/test/test_eta_ai.ml:320:  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
- packages/eta-ai/test/test_eta_ai.ml:325:  Eio.Switch.run @@ fun sw ->
- packages/eta-ai/test/test_eta_ai.ml:326:  let tracer = Eta.Tracer.in_memory () in
- packages/eta-ai/test/test_eta_ai.ml:328:    Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
- packages/eta-ai/test/test_eta_ai.ml:329:      ~tracer:(Eta.Tracer.as_capability tracer) ()
- packages/eta-ai/test/test_eta_ai.ml:335:  Eio.Switch.run @@ fun sw ->
- packages/eta-ai/test/test_eta_ai.ml:336:  let tracer = Eta.Tracer.in_memory () in
- packages/eta-ai/test/test_eta_ai.ml:337:  let logger = Eta.Logger.in_memory () in
- packages/eta-ai/test/test_eta_ai.ml:339:    Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
- packages/eta-ai/test/test_eta_ai.ml:340:      ~tracer:(Eta.Tracer.as_capability tracer)
- packages/eta-ai/test/test_eta_ai.ml:341:      ~logger:(Eta.Logger.as_capability logger) ()
- packages/eta-ai/test/test_eta_ai.ml:346:  match Eta.Runtime.run rt effect with
- packages/eta-ai/test/test_eta_ai.ml:377:  | Some release -> Http.Body.Stream.of_bytes ~release (chunk_string value)
- packages/eta-ai/test/test_eta_ai.ml:378:  | None -> Http.Body.Stream.of_bytes (chunk_string value)
- packages/eta-ai/test/test_eta_ai.ml:526:        Eta.Effect.unit)
- packages/eta-ai/test/test_eta_ai.ml:558:let span_attr key (span : Eta.Tracer.span) = List.assoc_opt key span.attrs
- packages/eta-ai/test/test_eta_ai.ml:566:      (fun (span : Eta.Tracer.span) -> String.equal span.name name && pred span)
- packages/eta-ai/test/test_eta_ai.ml:577:         (Eta.Effect.pure (telemetry_response ())))
- packages/eta-ai/test/test_eta_ai.ml:581:  let spans = Eta.Tracer.dump tracer in
- packages/eta-ai/test/test_eta_ai.ml:584:  Alcotest.(check bool) "kind" true (span.kind = Eta.Tracer.Client);
- packages/eta-ai/test/test_eta_ai.ml:612:    (Eta.Effect.concat
- packages/eta-ai/test/test_eta_ai.ml:616:           Eta.Effect.unit;
- packages/eta-ai/test/test_eta_ai.ml:617:         with_embeddings_span ~usage stream_provider embeddings Eta.Effect.unit;
- packages/eta-ai/test/test_eta_ai.ml:619:  let spans = Eta.Tracer.dump tracer in
- packages/eta-ai/test/test_eta_ai.ml:635:    Eta.Effect.named_kind ~kind:Eta.Capabilities.Client "HTTP POST"
- packages/eta-ai/test/test_eta_ai.ml:636:      Eta.Effect.unit
- packages/eta-ai/test/test_eta_ai.ml:641:    |> Eta.Effect.bind (fun () ->
- packages/eta-ai/test/test_eta_ai.ml:643:             Eta.Effect.unit)
- packages/eta-ai/test/test_eta_ai.ml:644:    |> Eta.Effect.bind (fun () ->
- packages/eta-ai/test/test_eta_ai.ml:645:           Eta.Effect.pure
- packages/eta-ai/test/test_eta_ai.ml:651:  let spans = Eta.Tracer.dump tracer in
- packages/eta-ai/test/test_eta_ai.ml:654:       (fun (span : Eta.Tracer.span) -> String.equal span.name "HTTP POST")
- packages/eta-ai/test/test_eta_ai.ml:672:     Eta.Runtime.run rt
- packages/eta-ai/test/test_eta_ai.ml:674:          (Eta.Effect.fail error))
- packages/eta-ai/test/test_eta_ai.ml:679:    find_span (Eta.Tracer.dump tracer) "chat gpt-4o-mini" (fun _ -> true)
- packages/eta-ai/test/test_eta_ai.ml:683:  | Eta.Tracer.Error _ -> ()
- packages/eta-ai/test/test_eta_ai.ml:697:let span_contains_secret secret (span : Eta.Tracer.span) =
- packages/eta-ai/test/test_eta_ai.ml:705:let log_contains_secret secret (record : Eta.Logger.record) =
- packages/eta-ai/test/test_eta_ai.ml:719:    Eta.Effect.log
- packages/eta-ai/test/test_eta_ai.ml:720:      ~attrs:[ ("authorization", "Bearer " ^ Redacted.value key) ]
- packages/eta-ai/test/test_eta_ai.ml:723:    |> Eta.Effect.bind (fun () -> Eta.Effect.pure (telemetry_response ()))
- packages/eta-ai/test/test_eta_ai.ml:728:  let spans = Eta.Tracer.dump tracer in
- packages/eta-ai/test/test_eta_ai.ml:729:  let logs = Eta.Logger.dump logger in
<!-- END DEP_MATCHES -->
