(* P1 baseline service 1: health/readiness + graceful shutdown.

   Built using ONLY existing public primitives:
     - Eta_http.Server.{Request,Response,Handler}
     - a plain bool ref for readiness state (application-owned, no env channel)
     - Eta_http_eio.Server.run_h1 ~stop for graceful shutdown

   This file measures where the friction is. The handler-only test below runs
   the handler against a synthetic Request.t (no socket), like
   examples/http_handlers.ml. The graceful-shutdown runner is [run_server]. *)
open Eta

module Server = Eta_http.Server

(* --- application-owned readiness state: an ordinary value, no Layer/Context --- *)
type readiness = { ready : bool ref }

let make_readiness init = { ready = ref init }

(* The handler: manual path matching. No router. Two endpoints:
   /health (liveness) and /ready (readiness, reflects the ref). *)
let handler (rd : readiness) : Server.handler =
  Server.Handler.of_sync (fun request ->
      match request.Server.Request.path with
      | "/health" -> Server.Response.text ~status:200 "ok\n"
      | "/ready" ->
          if !(rd.ready) then Server.Response.text ~status:200 "ready\n"
          else Server.Response.text ~status:503 "not ready\n"
      | _ -> Server.Response.text ~status:404 "not found\n")

(* --- graceful shutdown recipe using existing primitives ---
   `run_h1` takes `?stop:unit Eio.Promise.t`; resolving it stops the listener.
   On SIGTERM we flip readiness to false, then resolve `stop` to drain. *)
let run_server port =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let rd = make_readiness true in
  let stop, resolve_stop = Eio.Promise.create () in
  let on_sigterm (_ : int) =
    rd.ready := false;
    Eio.Promise.resolve resolve_stop ()
  in
  ignore
    (Sys.signal Sys.sigterm (Sys.Signal_handle on_sigterm)
     [@alert.unsafe_multidomain ""]);
  Eta_http_eio.Server.run_h1 ~sw ~net ~clock ~stop
    ~addr:(`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    (handler rd)

(* --------------------------------------------------------------------- *)
(* Handler-only test: no socket. Builds a Request.t and runs the effect. *)

let request ?(meth = "GET") path =
  {
    Server.Request.id = lazy ("p1a:" ^ path);
    version = Eta_http.Core.Version.H1_1;
    scheme = "http";
    authority = Some "localhost";
    method_ = meth;
    target = path;
    path;
    query = None;
    headers = Eta_http.Core.Header.empty;
    body = Server.Body.empty ();
    trailers = (fun () -> Effect.pure Eta_http.Core.Header.empty);
    peer = { address = Some "127.0.0.1"; port = Some 8080 };
    tls = false;
    alpn_protocol = None;
    stream_id = None;
    connection_id = "p1a-conn";
  }

let cause_string cause =
  let buf = Buffer.create 64 in
  let f = Format.formatter_of_buffer buf in
  Format.fprintf f "%a" (Cause.pp Server.Error.pp) cause;
  Buffer.contents buf

let assert_status rt label rd path expected_status =
  let h = handler rd in
  match Eta_eio.Runtime.run rt (h (request path)) with
  | Exit.Ok resp when Server.Response.status resp = expected_status ->
      Printf.printf "[PASS] %s: %d\n" label expected_status
  | Exit.Ok resp ->
      failwith
        (Printf.sprintf "[FAIL] %s: expected %d, got %d" label expected_status
           (Server.Response.status resp))
  | Exit.Error cause ->
      failwith (Printf.sprintf "[FAIL] %s: %s" label (cause_string cause))

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock stdenv in
  let rt = Eta_eio.Runtime.create ~sw ~clock () in
  let rd = make_readiness true in
  assert_status rt "health" rd "/health" 200;
  assert_status rt "ready-up" rd "/ready" 200;
  rd.ready := false;
  assert_status rt "ready-down" rd "/ready" 503;
  assert_status rt "not-found" rd "/nope" 404;
  print_endline "p1a_health: all handler-only assertions passed"
