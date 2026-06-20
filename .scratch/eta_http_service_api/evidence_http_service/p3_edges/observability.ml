(* P3 fixture 4 — route-template observability propagation.

   THE concrete gap P0 flagged: Server.Semconv.request_attrs emits the concrete
   matched path (url.path = "/items/7"), never the route TEMPLATE
   ("/items/{id}"). So spans/metrics/access logs lose the "which endpoint?"
   signal and explode cardinality.

   This proves a service layer can carry the matched template and emit it as the
   OTel "http.route" attribute WITHOUT mutating the immutable Server.Request.t,
   while INHERITING the existing url.query redaction. *)
open Eta

module S = Eta_http.Server

let request ?(query = None) path =
  {
    S.Request.id = lazy "p3o";
    version = Eta_http.Core.Version.H1_1;
    scheme = "http";
    authority = Some "localhost";
    method_ = "GET";
    target = path;
    path;
    query;
    headers = Eta_http.Core.Header.empty;
    body = S.Body.empty ();
    trailers = (fun () -> Effect.pure Eta_http.Core.Header.empty);
    peer = { address = Some "127.0.0.1"; port = Some 8080 };
    tls = false;
    alpn_protocol = None;
    stream_id = None;
    connection_id = "p3o-conn";
  }

(* build a router that stamps the matched TEMPLATE into attrs, inherited from
   Server.Semconv (so url.query redaction is preserved). *)
let build_handler () =
  let routes = [ ("/items/{id}", "items-id"); ("/health", "health") ] in
  let tmpl_of = List.map (fun (p, v) -> (v, p)) routes in
  let router = Eta_router.Router.create () in
  List.iter (fun (tmpl, v) -> ignore (Eta_router.Router.insert router tmpl v)) routes;
  fun request ->
    let path = request.Eta_http.Server.Request.path in
    match Eta_router.Router.at router path with
    | Error _ -> Effect.pure (S.Response.text ~status:404 "nf\n")
    | Ok m ->
      let template = List.assoc m.Eta_router.Match.value tmpl_of in
      let base = Eta_http.Observability.Server.Semconv.request_attrs ~emit_url_full:false request in
      let attrs = ("http.route", template) :: base in
      let hdrs =
        List.fold_left
          (fun acc (k, v) -> Eta_http.Core.Header.unsafe_add k v acc)
          (S.Response.headers (S.Response.text "ok")) attrs
      in
      Effect.pure (S.Response.make ~status:200 ~body:(S.Response.Body.string "ok") ~headers:hdrs ())

let header_value name resp =
  Eta_http.Core.Header.get name (S.Response.headers resp)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let h = build_handler () in
  let check label req expected_route expected_query_attr =
    match Eta_eio.Runtime.run rt (h req) with
    | Exit.Ok resp ->
      let route = header_value "http.route" resp in
      let q = header_value "url.query.redacted" resp in
      let q_norm = Option.value q ~default:"<none>" in
      if route = Some expected_route && q = expected_query_attr then
        Printf.printf "[PASS p3-obs] %-16s http.route=%s query=%s\n" label
          expected_route q_norm
      else
        failwith
          (Printf.sprintf "[FAIL p3-obs] %s route=%s query=%s" label
             (Option.value route ~default:"?") q_norm)
    | Exit.Error cause ->
      let buf = Buffer.create 64 in
      Format.fprintf (Format.formatter_of_buffer buf) "%a" (Cause.pp S.Error.pp) cause;
      failwith (Printf.sprintf "[FAIL p3-obs] %s: %s" label (Buffer.contents buf))
  in
  (* http.route carries the TEMPLATE (low cardinality), not /items/7.
     No query on this request -> no url.query.redacted attr. *)
  check "items/7" (request "/items/7") "/items/{id}" None;
  check "health" (request "/health") "/health" None;
  (* query present -> emitted as <redacted> (inherited Server.Semconv behavior) *)
  check "items/7?q=secret"
    (request "/items/7" ~query:(Some "secret"))
    "/items/{id}" (Some "<redacted>");
  print_endline "p3_observability: route-template + redaction preserved"
