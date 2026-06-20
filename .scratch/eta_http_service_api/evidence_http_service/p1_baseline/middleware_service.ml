(* P1 baseline service 3: a middleware stack using ONLY existing primitives.

   There is no Middleware.t today; middleware is ordinary function
   composition [handler -> handler]. This file measures that friction:
     - each concern is a small wrapper function;
     - composition is right-to-left function pipeline;
     - ordering must be reasoned by hand (outermost runs first);
     - request id / access log / tracing must be threaded by closures and
       response headers, since Request.t is immutable.

   Stack (outermost -> innermost):
     access_log  >  request_id  >  auth  >  concurrency_limit  >  timeout  > route
   i.e. [route |> timeout |> concurrency_limit |> auth |> request_id |> access_log]. *)
open Eta

module Server = Eta_http.Server

(* ----------------------------------------------------------------------- *)
(* Middleware 1: access log. Wraps the inner handler; logs method/path and
   the final status. Uses Eta.Logger.in_memory just to have a sink; a real
   service uses the runtime logger. *)
let access_log (inner : Server.handler) : Server.handler =
  let open Eta.Syntax in
  fun request ->
    let* response = inner request in
    Printf.printf "[access] %s %s -> %d\n%!"
      request.Server.Request.method_ request.Server.Request.path
      (Server.Response.status response);
    Effect.pure response

(* Middleware 2: request id. Reads X-Request-Id if present, else generates one;
   echoes it on the response. No way to attach it to Request.t (immutable), so
   the inner handler must read it from request headers. *)
let request_id (inner : Server.handler) : Server.handler =
  let open Eta.Syntax in
  fun request ->
    let id =
      match Eta_http.Core.Header.get "x-request-id" request.Server.Request.headers with
      | Some v -> v
      | None -> Lazy.force request.Server.Request.id
    in
    let* response = inner request in
    let h =
      Eta_http.Core.Header.unsafe_add "x-request-id" id
        (Server.Response.headers response)
    in
    Effect.pure (Server.Response.make ~status:(Server.Response.status response)
                   ~body:(Server.Response.body response) ~headers:h ())

(* Middleware 3: auth hook. Requires a Bearer token; 401 otherwise. The token
   check is application-owned (closure over an auth verifier). *)
let auth (verify : string -> bool) (inner : Server.handler) : Server.handler =
  let prefix = "Bearer " in
  let unauthorized () =
    Effect.pure (Server.Response.text ~status:401 "unauthorized\n")
  in
  fun request ->
    match Eta_http.Core.Header.get "authorization" request.Server.Request.headers with
    | None -> unauthorized ()
    | Some v when
        String.length v > String.length prefix
        && String.sub v 0 (String.length prefix) = prefix
      ->
        let token =
          String.sub v (String.length prefix) (String.length v - String.length prefix)
        in
        if verify token then inner request else unauthorized ()
    | Some _ -> unauthorized ()

(* Middleware 4: per-route timeout. Uses Effect.timeout_as to fail with a typed
   Server.Error (Handler_timeout) when the inner handler is too slow. *)
let timeout (budget : Eta.Duration.t) (inner : Server.handler) : Server.handler =
  fun request ->
    let ctx =
      Server.Error.make ~method_:request.Server.Request.method_
        ~target:request.Server.Request.target
        (Server.Error.Handler_timeout { timeout_ms = Some (Eta.Duration.to_ms budget) })
    in
    Effect.timeout_as budget ~on_timeout:ctx (inner request)

(* Middleware 5: concurrency admission. Bounds in-flight handlers with a
   Semaphore; over-limit requests wait (backpressure), not reject. *)
let concurrency_limit (sem : Eta.Semaphore.t) (inner : Server.handler) :
  Server.handler =
  fun request -> Eta.Semaphore.with_permits sem 1 (fun () -> inner request)

(* ----------------------------------------------------------------------- *)
(* The route (innermost). A trivial echo of who the caller is. *)
let route : Server.handler =
  Server.Handler.of_sync (fun request ->
      match request.Server.Request.path with
      | "/whoami" -> Server.Response.text "ok\n"
      | _ -> Server.Response.text ~status:404 "not found\n")

(* The composed service. Order is right-to-left function application: route is
   innermost, access_log is outermost. *)
let service ~verify =
  let sem = Eta.Semaphore.make ~permits:8 in
  route
  |> timeout (Eta.Duration.ms 5000)
  |> concurrency_limit sem
  |> auth verify
  |> request_id
  |> access_log

(* --------------------------------------------------------------------- *)
(* Handler-only test: synthetic Request.t with headers, no socket. *)

let request ?(headers = []) meth path =
  {
    Server.Request.id = lazy "p1c";
    version = Eta_http.Core.Version.H1_1;
    scheme = "http";
    authority = Some "localhost";
    method_ = meth;
    target = path;
    path;
    query = None;
    headers = Eta_http.Core.Header.unsafe_of_list headers;
    body = Server.Body.empty ();
    trailers = (fun () -> Effect.pure Eta_http.Core.Header.empty);
    peer = { address = Some "127.0.0.1"; port = Some 8080 };
    tls = false;
    alpn_protocol = None;
    stream_id = None;
    connection_id = "p1c-conn";
  }

let status_of rt svc headers path expected =
  match Eta_eio.Runtime.run rt (svc (request "GET" path ~headers)) with
  | Exit.Ok resp ->
      let s = Server.Response.status resp in
      if s = expected then Printf.printf "[PASS] %s -> %d\n" path expected
      else failwith (Printf.sprintf "[FAIL] %s expected %d got %d" path expected s)
  | Exit.Error cause ->
      let buf = Buffer.create 64 in
      Format.fprintf (Format.formatter_of_buffer buf) "%a"
        (Cause.pp Server.Error.pp) cause;
      failwith (Printf.sprintf "[FAIL] %s error: %s" path (Buffer.contents buf))

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let svc = service ~verify:(fun tok -> String.equal tok "sekrit") in
  (* authorized *)
  status_of rt svc [ ("authorization", "Bearer sekrit") ] "/whoami" 200;
  (* missing auth *)
  status_of rt svc [] "/whoami" 401;
  (* wrong token *)
  status_of rt svc [ ("authorization", "Bearer nope") ] "/whoami" 401;
  print_endline "p1c_middleware: all handler-only assertions passed"
