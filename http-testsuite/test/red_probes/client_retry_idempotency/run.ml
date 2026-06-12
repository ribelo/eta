(* Red probe: client retry and idempotency behavior.
   These probes intentionally exercise Eta_http.Retry and Idempotency decisions
   and report whether they match the documented contract. Exit code is always 0:
   this is a bug finder, not a green gate. *)

open Eta_http_testsuite

(* ---------------------------------------------------------------------------
   Outcome model and reporting
   --------------------------------------------------------------------------- *)

type outcome =
  | Pass of string
  | Fail of string
  | Hang
  | Crash of string
  | Policy_gap of string

let string_of_outcome = function
  | Pass d -> "PASS", d
  | Fail d -> "FAIL", d
  | Hang -> "HANG", ""
  | Crash d -> "CRASH", d
  | Policy_gap d -> "POLICY_GAP", d

let empty_response status =
  Eta_http.Response.make ~status
    ~body:(Eta_http.Body.Stream.of_bytes [])
    ()

let runtime ~env ~sw =
  Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()

let run_probe ~env ~name ~deadline_sec probe =
  try
    Eio.Switch.run @@ fun sw ->
    let clock = Eio.Stdenv.clock env in
    Eio.Time.with_timeout_exn clock deadline_sec (fun () -> probe ~env ~sw)
  with
  | Eio.Time.Timeout -> Hang
  | exn -> Crash (Printexc.to_string exn)

let report name outcome =
  let status, detail = string_of_outcome outcome in
  if String.equal detail "" then Printf.printf "probe %s %s\n%!" name status
  else Printf.printf "probe %s %s %s\n%!" name status detail

(* ---------------------------------------------------------------------------
   Custom client helpers for deterministic retry tests
   --------------------------------------------------------------------------- *)

let custom_client ~attempts_ref request_fn =
  let request req =
    incr attempts_ref;
    request_fn req
  in
  Eta_http.Client.make_custom ~protocol:H1 ~request
    ~stats:(fun () ->
      Eta.Effect.pure
        {
          Eta_http.Client.protocol = H1;
          active = 0;
          idle = 0;
          capacity = 0;
          opened = !attempts_ref;
          released = 0;
        })
    ~shutdown:(fun () -> Eta.Effect.unit)

let consume_request_body req =
  let source = Eta_http.Request.body_source req.Eta_http.Request.body in
  Eta_http.Body.Source.to_stream source
  |> Eta_http.Body.Stream.read_all
  |> Eta.Effect.map (fun _ -> ())

(* ---------------------------------------------------------------------------
   1. Default policy must NOT retry a non-idempotent POST without an
      idempotency key, even when the server returns 503.
   --------------------------------------------------------------------------- *)

let probe_post_default_no_retry ~env ~sw =
  let attempts = ref 0 in
  let client =
    custom_client ~attempts_ref:attempts (fun _req ->
        Eta.Effect.pure (empty_response 503))
  in
  let request = Eta_http.Request.make "POST" "http://example.test/no-retry" in
  let rt = runtime ~env ~sw in
  match Eta.Runtime.run rt (Eta_http.Client.request_with_retry client request) with
  | Eta.Exit.Ok response when response.Eta_http.Response.status = 503 && !attempts = 1 ->
      Pass (Printf.sprintf "attempts=%d" !attempts)
  | Eta.Exit.Ok response ->
      Fail
        (Printf.sprintf "status=%d attempts=%d (expected 503, 1 attempt)"
           response.Eta_http.Response.status !attempts)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail (Printf.sprintf "attempts=%d error=%s" !attempts msg)

(* ---------------------------------------------------------------------------
   2. POST with a valid Idempotency-Key header must be retried on 503.
   --------------------------------------------------------------------------- *)

let probe_post_idempotency_key_retries ~env ~sw =
  let attempts = ref 0 in
  let client =
    custom_client ~attempts_ref:attempts (fun _req ->
        let status = if !attempts < 3 then 503 else 200 in
        Eta.Effect.pure (empty_response status))
  in
  let request =
    Eta_http.Request.make ~headers:[ ("Idempotency-Key", "key-abc") ] "POST"
      "http://example.test/key-retry"
  in
  let rt = runtime ~env ~sw in
  match Eta.Runtime.run rt (Eta_http.Client.request_with_retry client request) with
  | Eta.Exit.Ok response
    when response.Eta_http.Response.status = 200 && !attempts = 3 ->
      Pass (Printf.sprintf "attempts=%d" !attempts)
  | Eta.Exit.Ok response ->
      Fail
        (Printf.sprintf "status=%d attempts=%d (expected 200, 3 attempts)"
           response.Eta_http.Response.status !attempts)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail (Printf.sprintf "attempts=%d error=%s" !attempts msg)

(* ---------------------------------------------------------------------------
   3. A streaming request body is one-shot; default policy must NOT retry even
      an idempotent GET when the body cannot be replayed.
   --------------------------------------------------------------------------- *)

let probe_streaming_body_no_retry ~env ~sw =
  let attempts = ref 0 in
  let stream_reads = ref 0 in
  let body_stream =
    Eta_http.Body.Stream.of_reader (fun () ->
        if !stream_reads > 0 then Eta.Effect.pure Eta_http.Body.Stream.End
        else (
          incr stream_reads;
          Eta.Effect.pure (Eta_http.Body.Stream.Chunk (Bytes.of_string "x"))))
  in
  let client =
    custom_client ~attempts_ref:attempts (fun req ->
        consume_request_body req
        |> Eta.Effect.map (fun () -> empty_response 503))
  in
  let request =
    Eta_http.Request.make ~body:(Stream body_stream) "GET"
      "http://example.test/stream-body"
  in
  let rt = runtime ~env ~sw in
  match Eta.Runtime.run rt (Eta_http.Client.request_with_retry client request) with
  | Eta.Exit.Ok response when response.Eta_http.Response.status = 503 && !attempts = 1 ->
      Pass (Printf.sprintf "attempts=%d" !attempts)
  | Eta.Exit.Ok response ->
      Fail
        (Printf.sprintf "status=%d attempts=%d (expected 503, 1 attempt)"
           response.Eta_http.Response.status !attempts)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail (Printf.sprintf "attempts=%d error=%s" !attempts msg)

(* ---------------------------------------------------------------------------
   4. A rewindable request body must be replayed across retries.
   --------------------------------------------------------------------------- *)

let probe_rewindable_body_replayed ~env ~sw =
  let attempts = ref 0 in
  let makes = ref 0 in
  let make () =
    incr makes;
    Eta_http.Body.Stream.of_bytes [ Bytes.of_string "body" ]
  in
  let client =
    custom_client ~attempts_ref:attempts (fun req ->
        consume_request_body req
        |> Eta.Effect.map (fun () ->
               let status = if !attempts < 2 then 503 else 200 in
               empty_response status))
  in
  let request =
    Eta_http.Request.make
      ~headers:[ ("Idempotency-Key", "key-rw") ]
      ~body:(Rewindable_stream { length = Some 4; make })
      "POST" "http://example.test/rewindable"
  in
  let rt = runtime ~env ~sw in
  match Eta.Runtime.run rt (Eta_http.Client.request_with_retry client request) with
  | Eta.Exit.Ok response
    when response.Eta_http.Response.status = 200 && !attempts = 2 && !makes = 2 ->
      Pass (Printf.sprintf "attempts=%d makes=%d" !attempts !makes)
  | Eta.Exit.Ok response ->
      Fail
        (Printf.sprintf "status=%d attempts=%d makes=%d (expected 200,2,2)"
           response.Eta_http.Response.status !attempts !makes)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail (Printf.sprintf "attempts=%d makes=%d error=%s" !attempts !makes msg)

(* ---------------------------------------------------------------------------
   5. Retry delays must actually be observed between attempts.
   --------------------------------------------------------------------------- *)

let probe_retry_delay_observed ~env ~sw =
  let attempts = ref 0 in
  let client =
    custom_client ~attempts_ref:attempts (fun _req ->
        let status = if !attempts < 3 then 503 else 200 in
        Eta.Effect.pure (empty_response status))
  in
  let request = Eta_http.Request.make "GET" "http://example.test/delay" in
  let policy =
    Eta_http.Retry_policy.make ~mode:Default ~max_attempts:3
      ~schedule:(Eta.Schedule.fixed (Eta.Duration.ms 250))
      ~respect_retry_after:false ()
  in
  let rt = runtime ~env ~sw in
  let start = Unix.gettimeofday () in
  let result =
    Eta.Runtime.run rt (Eta_http.Client.request_with_retry ~policy client request)
  in
  let elapsed_ms = (Unix.gettimeofday () -. start) *. 1000.0 in
  match result with
  | Eta.Exit.Ok response when response.Eta_http.Response.status = 200 && !attempts = 3 ->
      if elapsed_ms >= 450.0 then
        Pass
          (Printf.sprintf "attempts=%d elapsed_ms=%.0f" !attempts elapsed_ms)
      else
        Fail
          (Printf.sprintf "delays ignored: attempts=%d elapsed_ms=%.0f"
             !attempts elapsed_ms)
  | Eta.Exit.Ok response ->
      Fail
        (Printf.sprintf "status=%d attempts=%d elapsed_ms=%.0f"
           response.Eta_http.Response.status !attempts elapsed_ms)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail
        (Printf.sprintf "attempts=%d elapsed_ms=%.0f error=%s" !attempts
           elapsed_ms msg)

(* ---------------------------------------------------------------------------
   6. Cancellation during a retry delay must not hang; a total timeout wrapped
      around the retried request should fire while waiting between attempts.
   --------------------------------------------------------------------------- *)

let probe_cancellation_during_retry_delay ~env ~sw =
  let attempts = ref 0 in
  let client =
    custom_client ~attempts_ref:attempts (fun _req ->
        Eta.Effect.pure (empty_response 503))
  in
  let request = Eta_http.Request.make "GET" "http://example.test/cancel" in
  let policy =
    Eta_http.Retry_policy.make ~mode:Default ~max_attempts:100
      ~schedule:(Eta.Schedule.fixed (Eta.Duration.ms 500))
      ~respect_retry_after:false ()
  in
  let rt = runtime ~env ~sw in
  let on_timeout =
    Eta_http.Error.make ~method_:"GET" ~uri:"http://example.test/cancel"
      (Total_request_timeout { timeout_ms = Some 200 })
  in
  let start = Unix.gettimeofday () in
  let result =
    Eta.Runtime.run rt
      (Eta_http.Client.request_with_retry ~policy client request
      |> Eta.Effect.timeout_as (Eta.Duration.ms 200) ~on_timeout)
  in
  let elapsed_ms = (Unix.gettimeofday () -. start) *. 1000.0 in
  match result with
  | Eta.Exit.Error cause when !attempts = 1 && elapsed_ms < 400.0 ->
      Pass
        (Printf.sprintf "attempts=%d elapsed_ms=%.0f timeout_before_retry"
           !attempts elapsed_ms)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail
        (Printf.sprintf
           "timeout did not cancel retry delay: attempts=%d elapsed_ms=%.0f \
            error=%s"
           !attempts elapsed_ms msg)
  | Eta.Exit.Ok _ ->
      Fail (Printf.sprintf "attempts=%d expected timeout" !attempts)

(* ---------------------------------------------------------------------------
   7. A streaming request body must not be retried even with an idempotency key.
   --------------------------------------------------------------------------- *)

let probe_streaming_body_ignores_idempotency_key ~env ~sw =
  let attempts = ref 0 in
  let stream_reads = ref 0 in
  let body_stream =
    Eta_http.Body.Stream.of_reader (fun () ->
        if !stream_reads > 0 then Eta.Effect.pure Eta_http.Body.Stream.End
        else (
          incr stream_reads;
          Eta.Effect.pure (Eta_http.Body.Stream.Chunk (Bytes.of_string "x"))))
  in
  let client =
    custom_client ~attempts_ref:attempts (fun req ->
        consume_request_body req
        |> Eta.Effect.map (fun () -> empty_response 503))
  in
  let request =
    Eta_http.Request.make
      ~headers:[ ("Idempotency-Key", "key-stream") ]
      ~body:(Stream body_stream) "POST" "http://example.test/stream-key"
  in
  let rt = runtime ~env ~sw in
  match Eta.Runtime.run rt (Eta_http.Client.request_with_retry client request) with
  | Eta.Exit.Ok response when response.Eta_http.Response.status = 503 && !attempts = 1 ->
      Pass (Printf.sprintf "attempts=%d" !attempts)
  | Eta.Exit.Ok response ->
      Fail
        (Printf.sprintf "status=%d attempts=%d (expected 503, 1 attempt)"
           response.Eta_http.Response.status !attempts)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail (Printf.sprintf "attempts=%d error=%s" !attempts msg)

(* ---------------------------------------------------------------------------
   8. An Idempotency-Key header containing only whitespace must not be treated
      as a valid idempotency key.
   --------------------------------------------------------------------------- *)

let probe_idempotency_key_whitespace_ignored ~env ~sw =
  let attempts = ref 0 in
  let client =
    custom_client ~attempts_ref:attempts (fun _req ->
        Eta.Effect.pure (empty_response 503))
  in
  let request =
    Eta_http.Request.make
      ~headers:[ ("Idempotency-Key", "   ") ]
      "POST" "http://example.test/blank-key"
  in
  let rt = runtime ~env ~sw in
  match Eta.Runtime.run rt (Eta_http.Client.request_with_retry client request) with
  | Eta.Exit.Ok response when response.Eta_http.Response.status = 503 && !attempts = 1 ->
      Pass (Printf.sprintf "attempts=%d" !attempts)
  | Eta.Exit.Ok response ->
      Fail
        (Printf.sprintf "status=%d attempts=%d (expected 503, 1 attempt)"
           response.Eta_http.Response.status !attempts)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail (Printf.sprintf "attempts=%d error=%s" !attempts msg)

(* ---------------------------------------------------------------------------
   9. Non-idempotent POST must not be retried on transport failures either.
   --------------------------------------------------------------------------- *)

let probe_post_error_no_retry ~env ~sw =
  let attempts = ref 0 in
  let client =
    custom_client ~attempts_ref:attempts (fun _req ->
        Eta.Effect.fail
          (Eta_http.Error.make ~method_:"POST"
             ~uri:"http://example.test/error-no-retry"
             (Connection_closed { during = Http_request })))
  in
  let request =
    Eta_http.Request.make "POST" "http://example.test/error-no-retry"
  in
  let rt = runtime ~env ~sw in
  match Eta.Runtime.run rt (Eta_http.Client.request_with_retry client request) with
  | Eta.Exit.Error _ when !attempts = 1 ->
      Pass (Printf.sprintf "attempts=%d" !attempts)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail
        (Printf.sprintf "attempts=%d error=%s (expected 1 attempt)" !attempts
           msg)
  | Eta.Exit.Ok response ->
      Fail
        (Printf.sprintf "status=%d attempts=%d (expected error, 1 attempt)"
           response.Eta_http.Response.status !attempts)

(* ---------------------------------------------------------------------------
   9. Eta does not auto-follow redirects. A 302 response must be returned to
      the caller unchanged and must not be retried either.
   --------------------------------------------------------------------------- *)

let probe_redirect_not_followed ~env ~sw =
  let attempts = ref 0 in
  let client =
    custom_client ~attempts_ref:attempts (fun _req ->
        Eta.Effect.pure
          (Eta_http.Response.make ~status:302
             ~headers:[ ("Location", "http://example.test/elsewhere") ]
             ~body:(Eta_http.Body.Stream.of_bytes [])
             ()))
  in
  let request = Eta_http.Request.make "GET" "http://example.test/redirect" in
  let rt = runtime ~env ~sw in
  match Eta.Runtime.run rt (Eta_http.Client.request_with_retry client request) with
  | Eta.Exit.Ok response
    when response.Eta_http.Response.status = 302 && !attempts = 1 ->
      Pass (Printf.sprintf "attempts=%d" !attempts)
  | Eta.Exit.Ok response ->
      Fail
        (Printf.sprintf "status=%d attempts=%d (expected 302, 1 attempt)"
           response.Eta_http.Response.status !attempts)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail (Printf.sprintf "attempts=%d error=%s" !attempts msg)

(* ---------------------------------------------------------------------------
   10. Retry-After header must be respected as the inter-attempt delay.
   --------------------------------------------------------------------------- *)

let probe_retry_after_delay_observed ~env ~sw =
  let attempts = ref 0 in
  let client =
    custom_client ~attempts_ref:attempts (fun _req ->
        let status = if !attempts < 2 then 503 else 200 in
        Eta.Effect.pure
          (Eta_http.Response.make ~status
             ~headers:[ ("Retry-After", "1") ]
             ~body:(Eta_http.Body.Stream.of_bytes [])
             ()))
  in
  let request = Eta_http.Request.make "GET" "http://example.test/retry-after-1s" in
  let rt = runtime ~env ~sw in
  let start = Unix.gettimeofday () in
  let result =
    Eta.Runtime.run rt (Eta_http.Client.request_with_retry client request)
  in
  let elapsed_ms = (Unix.gettimeofday () -. start) *. 1000.0 in
  match result with
  | Eta.Exit.Ok response when response.Eta_http.Response.status = 200 && !attempts = 2 ->
      if elapsed_ms >= 800.0 then
        Pass (Printf.sprintf "attempts=%d elapsed_ms=%.0f" !attempts elapsed_ms)
      else
        Fail
          (Printf.sprintf "Retry-After ignored: attempts=%d elapsed_ms=%.0f"
             !attempts elapsed_ms)
  | Eta.Exit.Ok response ->
      Fail
        (Printf.sprintf "status=%d attempts=%d elapsed_ms=%.0f"
           response.Eta_http.Response.status !attempts elapsed_ms)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail (Printf.sprintf "attempts=%d elapsed_ms=%.0f error=%s" !attempts elapsed_ms msg)

(* ---------------------------------------------------------------------------
   11. Retry-After with a far-future HTTP-date value must be bounded.
   --------------------------------------------------------------------------- *)

let probe_retry_after_date_format ~env:_ ~sw:_ =
  let now = Unix.gettimeofday () in
  let far_future = "Fri, 31 Dec 9999 23:59:59 GMT" in
  match Eta_http.Retry_policy.retry_after ~now_s:now far_future with
  | None -> Pass "far-future HTTP-date rejected"
  | Some huge_delay ->
      let huge_ms = Eta.Duration.to_ms huge_delay in
      if huge_ms > 365 * 24 * 3600 * 1000 then
        Fail
          (Printf.sprintf "far-date-uncapped=%dms (potential DoS vector)"
             huge_ms)
      else
        Pass (Printf.sprintf "far-date-capped=%dms" huge_ms)

(* ---------------------------------------------------------------------------
   12. Always retry mode must retry a non-idempotent POST when the body is
      replayable.
   --------------------------------------------------------------------------- *)

let probe_always_mode_retries_non_idempotent ~env ~sw =
  let attempts = ref 0 in
  let client =
    custom_client ~attempts_ref:attempts (fun _req ->
        let status = if !attempts < 2 then 503 else 200 in
        Eta.Effect.pure (empty_response status))
  in
  let request = Eta_http.Request.make "POST" "http://example.test/always" in
  let policy = Eta_http.Retry_policy.make ~mode:Always ~max_attempts:2 () in
  let rt = runtime ~env ~sw in
  match
    Eta.Runtime.run rt (Eta_http.Client.request_with_retry ~policy client request)
  with
  | Eta.Exit.Ok response when response.Eta_http.Response.status = 200 && !attempts = 2 ->
      Pass (Printf.sprintf "attempts=%d" !attempts)
  | Eta.Exit.Ok response ->
      Fail
        (Printf.sprintf "status=%d attempts=%d (expected 200, 2 attempts)"
           response.Eta_http.Response.status !attempts)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail (Printf.sprintf "attempts=%d error=%s" !attempts msg)

(* ---------------------------------------------------------------------------
   13. Retry-After with a large delay must not bypass an outer total timeout.
   --------------------------------------------------------------------------- *)

let probe_retry_after_respects_total_timeout ~env ~sw =
  let attempts = ref 0 in
  let client =
    custom_client ~attempts_ref:attempts (fun _req ->
        Eta.Effect.pure
          (Eta_http.Response.make ~status:503
             ~headers:[ ("Retry-After", "3600") ]
             ~body:(Eta_http.Body.Stream.of_bytes [])
             ()))
  in
  let request = Eta_http.Request.make "GET" "http://example.test/retry-after" in
  let rt = runtime ~env ~sw in
  let on_timeout =
    Eta_http.Error.make ~method_:"GET"
      ~uri:"http://example.test/retry-after"
      (Total_request_timeout { timeout_ms = Some 300 })
  in
  let start = Unix.gettimeofday () in
  let result =
    Eta.Runtime.run rt
      (Eta_http.Client.request_with_retry client request
      |> Eta.Effect.timeout_as (Eta.Duration.ms 300) ~on_timeout)
  in
  let elapsed_ms = (Unix.gettimeofday () -. start) *. 1000.0 in
  match result with
  | Eta.Exit.Error _ when !attempts = 1 && elapsed_ms < 600.0 ->
      Pass
        (Printf.sprintf "attempts=%d elapsed_ms=%.0f timeout_before_retry"
           !attempts elapsed_ms)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail
        (Printf.sprintf
           "timeout did not cancel Retry-After delay: attempts=%d elapsed_ms=%.0f \
            error=%s"
           !attempts elapsed_ms msg)
  | Eta.Exit.Ok response ->
      Fail
        (Printf.sprintf "status=%d attempts=%d (expected timeout)"
           response.Eta_http.Response.status !attempts)

(* ---------------------------------------------------------------------------
   15. A rewindable body used with an idempotent method (GET) should retry on
      transport failure without requiring an idempotency key.
   --------------------------------------------------------------------------- *)

let probe_idempotent_rewindable_retries_on_error ~env ~sw =
  let attempts = ref 0 in
  let makes = ref 0 in
  let make () =
    incr makes;
    Eta_http.Body.Stream.of_bytes [ Bytes.of_string "payload" ]
  in
  let client =
    custom_client ~attempts_ref:attempts (fun req ->
        consume_request_body req
        |> Eta.Effect.bind (fun () ->
               if !attempts < 2 then
                 Eta.Effect.fail
                   (Eta_http.Error.make ~method_:"GET"
                      ~uri:"http://example.test/idempotent-rw"
                      (Connection_closed { during = Http_request }))
               else Eta.Effect.pure (empty_response 200)))
  in
  let request =
    Eta_http.Request.make
      ~body:(Rewindable_stream { length = Some 7; make })
      "GET" "http://example.test/idempotent-rw"
  in
  let rt = runtime ~env ~sw in
  match Eta.Runtime.run rt (Eta_http.Client.request_with_retry client request) with
  | Eta.Exit.Ok response
    when response.Eta_http.Response.status = 200 && !attempts = 2 && !makes = 2 ->
      Pass (Printf.sprintf "attempts=%d makes=%d" !attempts !makes)
  | Eta.Exit.Ok response ->
      Fail
        (Printf.sprintf "status=%d attempts=%d makes=%d (expected 200,2,2)"
           response.Eta_http.Response.status !attempts !makes)
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause in
      Fail (Printf.sprintf "attempts=%d makes=%d error=%s" !attempts !makes msg)

(* ---------------------------------------------------------------------------
   Orchestration
   --------------------------------------------------------------------------- *)

let probes ~env =
  [
    ("post_default_no_retry", 2.0, probe_post_default_no_retry);
    ("post_idempotency_key_retries", 2.0, probe_post_idempotency_key_retries);
    ("streaming_body_no_retry", 2.0, probe_streaming_body_no_retry);
    ("rewindable_body_replayed", 2.0, probe_rewindable_body_replayed);
    ("retry_delay_observed", 3.0, probe_retry_delay_observed);
    ("cancellation_during_retry_delay", 2.0, probe_cancellation_during_retry_delay);
    ("streaming_body_ignores_idempotency_key", 2.0, probe_streaming_body_ignores_idempotency_key);
    ("idempotency_key_whitespace_ignored", 2.0, probe_idempotency_key_whitespace_ignored);
    ("post_error_no_retry", 2.0, probe_post_error_no_retry);
    ("redirect_not_followed", 2.0, probe_redirect_not_followed);
    ("retry_after_delay_observed", 3.0, probe_retry_after_delay_observed);
    ("retry_after_date_format", 2.0, probe_retry_after_date_format);
    ("always_mode_retries_non_idempotent", 2.0, probe_always_mode_retries_non_idempotent);
    ("retry_after_respects_total_timeout", 2.0, probe_retry_after_respects_total_timeout);
    ("idempotent_rewindable_retries_on_error", 2.0, probe_idempotent_rewindable_retries_on_error);
  ]

let () =
  let results =
    Eio_main.run (fun env ->
        List.map
          (fun (name, deadline_sec, probe) ->
            let outcome = run_probe ~env ~name ~deadline_sec probe in
            report name outcome;
            (name, outcome))
          (probes ~env))
  in
  let findings = List.filter (fun (_, o) -> not (match o with Pass _ -> true | _ -> false)) results in
  Printf.printf "client_retry_idempotency done probes=%d findings=%d\n%!"
    (List.length results) (List.length findings)
