(* P3 fixture 3 — per-route timeout middleware (Tower layer).

   Proves that a per-route timeout, spelled as a [handler -> handler] middleware
   using Effect.timeout_as, converts an over-budget handler into a typed
   Server.Error (Handler_timeout) — which the server renders to a 503-class
   response on the wire. This is the middleware-component shape the strategic
   direction wants (each concern a composable handler->handler piece). *)
open Eta

module S = Eta_http.Server

(* per-route timeout middleware: fails typed on timeout *)
let timeout budget (inner : S.handler) : S.handler =
  fun request ->
    let on_timeout =
      S.Error.make ~method_:request.Eta_http.Server.Request.method_
        ~target:request.Eta_http.Server.Request.target
        (S.Error.Handler_timeout { timeout_ms = Some (Eta.Duration.to_ms budget) })
    in
    Effect.timeout_as budget ~on_timeout (inner request)

(* a handler that "sleeps" forever (never returns within budget) *)
let slow_handler : S.handler =
  fun _request -> Effect.delay (Eta.Duration.seconds 60) (Effect.pure (S.Response.text "late\n"))

let request () =
  {
    S.Request.id = lazy "p3t";
    version = Eta_http.Core.Version.H1_1;
    scheme = "http";
    authority = Some "localhost";
    method_ = "GET";
    target = "/x";
    path = "/x";
    query = None;
    headers = Eta_http.Core.Header.empty;
    body = S.Body.empty ();
    trailers = (fun () -> Effect.pure Eta_http.Core.Header.empty);
    peer = { address = Some "127.0.0.1"; port = Some 8080 };
    tls = false;
    alpn_protocol = None;
    stream_id = None;
    connection_id = "p3t-conn";
  }

let is_handler_timeout = function
  | Exit.Error (Cause.Fail err) ->
    (match err.S.Error.kind with S.Error.Handler_timeout _ -> true | _ -> false)
  | _ -> false

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let svc = timeout (Eta.Duration.ms 50) slow_handler in
  (* race the timeout-bound handler against a wall-clock guard so the test
     itself cannot hang for 60s *)
  let outcome =
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock stdenv) 2.0 (fun () ->
        Eta_eio.Runtime.run rt (svc (request ())))
  in
  if is_handler_timeout outcome then
    print_endline
      "[PASS p3-timeout] over-budget handler -> typed Handler_timeout (server renders 503-class)"
  else
    failwith "[FAIL p3-timeout] expected Handler_timeout typed failure"
