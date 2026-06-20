(* P3 fixture 2 — typed failure vs defect.

   Proves the two failure kinds are distinct and stay so through a service
   layer built on the shared Server.handler type:
     - a handler that [Effect.fail (Bad_request ...)] produces a typed
       Exit.Error (Fail ...) — the server renders it to a 400 on the wire.
     - a handler that raises an exception produces a Die defect — NOT a typed
       failure, NOT a silent 200. It surfaces as Exit.Error (Die ...).
   This is the contract extractors rely on (typed decode failure -> 400) and
   the contract that distinguishes expected domain errors from bugs. *)
open Eta

module S = Eta_http.Server

let bad_request () =
  S.Error.make ~method_:"GET" ~target:"/x" (S.Error.Bad_request { message = "nope" })

let typed_handler : S.handler =
  fun _request -> Effect.fail (bad_request ())

let defect_handler : S.handler =
  (* Effect.sync captures a raised exception as a Die defect (per docs/api-dx.md:
     Effect.sync is the synchronous defect boundary). Do not ignore it. *)
  fun _request ->
    Effect.sync (fun () ->
        failwith "boom")
    |> Effect.map (fun _ -> S.Response.text ~status:200 "should not reach")

let request () =
  {
    S.Request.id = lazy "p3f";
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
    connection_id = "p3f-conn";
  }

let classify = function
  | Exit.Ok _ -> "ok"
  | Exit.Error cause ->
    (match cause with
     | Cause.Fail _ -> "typed-fail"
     | Cause.Die _ -> "defect"
     | _ -> "other")

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let t = classify (Eta_eio.Runtime.run rt (typed_handler (request ()))) in
  let d = classify (Eta_eio.Runtime.run rt (defect_handler (request ()))) in
  if t = "typed-fail" && d = "defect" then
    print_endline
      ("[PASS p3-fail-vs-defect] typed=" ^ t ^ " defect=" ^ d
       ^ " (server renders typed Bad_request -> 400; defect -> 500)")
  else
    failwith
      (Printf.sprintf "[FAIL p3-fail-vs-defect] expected typed-fail/defect got %s/%s" t d)
