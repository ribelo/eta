module Loaded = Eta_http

let reclaim_eio_backend () =
  Gc.full_major ();
  Gc.compact ()

let run_linux_eio ?fallback f =
  reclaim_eio_backend ();
  Fun.protect ~finally:reclaim_eio_backend (fun () ->
      (* Keep normal queue capacity, but avoid per-runtime fixed-buffer
         memlock pressure in this many-short-schedulers test binary. *)
      Eio_linux.run ?fallback ~queue_depth:64 ~n_blocks:1 f)

let run_eio f =
  match Sys.getenv_opt "EIO_BACKEND" with
  | Some ("linux" | "io-uring") -> run_linux_eio f
  | None | Some "" ->
      run_linux_eio ~fallback:(fun _ -> Eio_main.run f) f
  | _ -> Eio_main.run f

let with_test_clock f =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eta_test.Test_clock.create () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(Eta_test.Test_clock.sleep clock)
      ~now_ms:(fun () -> Eta_test.Test_clock.now_ms clock)
      ()
  in
  f sw clock rt

let contains haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec loop index =
    index + n_len <= h_len
    && (String.equal needle (String.sub haystack index n_len)
       || loop (index + 1))
  in
  n_len = 0 || loop 0

let body_size_cap = 1_048_576

let expect_body_too_large label ~limit = function
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Body_too_large { limit = actual; length }; _ }) ->
      Alcotest.(check int) (label ^ " limit") limit actual;
      Alcotest.(check bool) (label ^ " length") true (length > limit)
  | Eta.Exit.Ok body ->
      Alcotest.failf "%s accepted %d bytes" label (Bytes.length body)
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s unexpected failure: %a" label
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let retry_response ?(headers = []) ?(release = fun () -> Eta.Effect.unit) status =
  Eta_http.Response.make ~status ~headers
    ~body:(Eta_http.Body.Stream.of_bytes ~release [])
    ()

let retry_client responses =
  let attempts = ref 0 in
  let request _ =
    let index = min !attempts (Array.length responses - 1) in
    incr attempts;
    Eta.Effect.pure (responses.(index) ())
  in
  ( attempts,
    Eta_http.Client.make_custom ~protocol:Eta_http.Client.H1 ~request
      ~stats:(fun () ->
        Eta.Effect.pure
          (Some
             {
               Eta_http.Client.protocol = H1;
               active = 0;
               idle = 0;
               capacity = 0;
               opened = !attempts;
               released = 0;
             }))
      ~shutdown:(fun () -> Eta.Effect.unit) )

let nested_server_handler_failure ~protocol
    (request : Eta_http.Server.Request.t) =
  let primary =
    Eta_http.Server.Error.make ~protocol ~method_:request.method_
      ~target:request.target
      (Expectation_failed { expectation = "nested-handler-failure" })
  in
  let finalizer_error =
    Eta_http.Server.Error.make ~protocol ~method_:request.method_
      ~target:request.target
      (Bad_request { message = "finalizer must not win" })
  in
  let later =
    Eta_http.Server.Error.make ~protocol ~method_:request.method_
      ~target:request.target
      (Handler_timeout { timeout_ms = Some 1 })
  in
  let finalizer =
    Eta.Cause.Finalizer.Fail
      { error = finalizer_error; rendered = "finalizer must not win" }
  in
  let cause =
    Eta.Cause.concurrent
      [
        Eta.Cause.sequential
          [
            Eta.Cause.suppressed ~primary:(Eta.Cause.fail primary) ~finalizer;
            Eta.Cause.fail later;
          ];
      ]
  in
  Eta.Spi.Expert.make ~leaf_name:"test.http.server.nested-handler-failure"
    (fun _context -> Eta.Exit.Error cause)

let server_span ~path tracer =
  match
    Eta.Tracer.dump tracer
    |> List.filter (fun span ->
           span.Eta.Tracer.kind = Eta.Tracer.Server
           && List.assoc_opt "url.path" span.attrs = Some path)
  with
  | [ span ] -> span
  | spans ->
      Alcotest.failf "expected one HTTP server span for %s, got %d" path
        (List.length spans)

let check_server_span ~path tracer =
  ignore (server_span ~path tracer : Eta.Tracer.span)

let check_server_error_span ~path tracer =
  let span = server_span ~path tracer in
  Alcotest.(check (option string)) "server span error type"
    (Some "handler_failed")
    (List.assoc_opt "error.type" span.attrs);
  Alcotest.(check (option string)) "server span error kind"
    (Some "Handler_failed")
    (List.assoc_opt "eta_http.error.kind" span.attrs);
  Alcotest.(check (option string)) "server span error layer" (Some "handler")
    (List.assoc_opt "eta_http.error.layer" span.attrs);
  match span.status with
  | Eta.Tracer.Error _ -> ()
  | Ok -> Alcotest.fail "expected errored HTTP server span, got Ok"
  | Cancelled -> Alcotest.fail "expected errored HTTP server span, got Cancelled"
