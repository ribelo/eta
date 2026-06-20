(* Extractors usage — same inn-shaped spec, now with typed extractors.

   Compare call-site readability to Branch A (manual param pull) and Branch C
   (declare-all endpoint). The handler now declares its dependencies as typed
   extractor arguments, like Axum's [Path<Id>] / [Json<Body>]. *)
open Eta

module S = Eta_http.Server

let store : (int * string) list ref = ref []

let json ?(status = 200) yo =
  let h =
    Eta_http.Core.Header.unsafe_add "content-type" "application/json"
      Eta_http.Core.Header.empty
  in
  S.Response.make ~status ~body:(S.Response.Body.string (Yojson.Safe.to_string yo))
    ~headers:h ()

(* domain decoder (plain result; could be eta_schema) *)
let decode_item = function
  | `Assoc fields ->
    (match List.assoc_opt "id" fields, List.assoc_opt "name" fields with
     | Some (`Int id), Some (`String name) -> Ok (id, name)
     | _ -> Error "expected {id,name}")
  | _ -> Error "expected object"

let service () : S.handler =
  let t = Branch_a.create () in
  Branch_a.add t "/health"
    (fun _req -> Effect.pure (S.Response.text ~status:200 "ok"));
  (* GET /items/{id} — extractor pulls & parses the int param, typed-failure on bad id *)
  Branch_a.add t "/items/{id}"
    (Extractors.route1 (Extractors.Param.int "id")
       (fun id ->
         Effect.pure
           (json (`Assoc [ ("id", `Int id); ("name", `String ("widget-" ^ string_of_int id)) ]))));
  (* POST /items — JSON body extracted and decoded; handler gets (int,string) *)
  Branch_a.add t ~methods:[ "POST" ] "/items"
    (Extractors.route1 (Extractors.json_body decode_item)
       (fun (id, name) ->
         if List.mem_assoc id !store then
           Effect.pure (S.Response.text ~status:409 "conflict\n")
         else begin
           store := (id, name) :: !store;
           Effect.pure
             (json ~status:201 (`Assoc [ ("id", `Int id); ("name", `String name) ]))
         end));
  Branch_a.compile t

let request ?(meth = "GET") path =
  {
    S.Request.id = lazy "p2e";
    version = Eta_http.Core.Version.H1_1;
    scheme = "http";
    authority = Some "localhost";
    method_ = meth;
    target = path;
    path;
    query = None;
    headers = Eta_http.Core.Header.empty;
    body = S.Body.empty ();
    trailers = (fun () -> Effect.pure Eta_http.Core.Header.empty);
    peer = { address = Some "127.0.0.1"; port = Some 8080 };
    tls = false;
    alpn_protocol = None;
    stream_id = None;
    connection_id = "p2e-conn";
  }

let request_with_body meth path body_str =
  let consumed = ref false in
  let body =
    S.Body.of_reader (fun () ->
      if !consumed then Effect.pure None
      else begin consumed := true; Effect.pure (Some (Bytes.of_string body_str)) end)
  in
  { (request ~meth path) with body }

let is_bad_request_cause = function
  | Eta.Cause.Fail err ->
    (match err.Eta_http.Server.Error.kind with
     | Eta_http.Server.Error.Bad_request _ -> true
     | _ -> false)
  | _ -> false

let check rt svc label req expected =
  (* Over a real socket the server renders handler Exit.Error (Bad_request) into
     a 400 response automatically (proven by socket_test). In a handler-only
     test we see the raw Exit, so accept either the rendered status OR the
     typed Bad_request failure (which the server renders to 400). *)
  match Eta_eio.Runtime.run rt (svc req) with
  | Exit.Ok resp when S.Response.status resp = expected ->
    Printf.printf "[PASS E] %-34s %d (ok)\n" label expected
  | Exit.Error cause when expected = 400 && is_bad_request_cause cause ->
    Printf.printf "[PASS E] %-34s %d (typed Bad_request -> 400 on the wire)\n" label expected
  | Exit.Ok resp ->
    failwith (Printf.sprintf "[FAIL E] %s: expected %d got %d" label expected (S.Response.status resp))
  | Exit.Error cause ->
    let buf = Buffer.create 64 in
    Format.fprintf (Format.formatter_of_buffer buf) "%a" (Cause.pp S.Error.pp) cause;
    failwith (Printf.sprintf "[FAIL E] %s error: %s" label (Buffer.contents buf))

let () =
  store := [];
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let svc = service () in
  check rt svc "GET /health" (request "/health") 200;
  check rt svc "GET /items/7" (request "/items/7") 200;
  check rt svc "GET /items/x (bad param)" (request "/items/x") 400;
  check rt svc "POST /items (create)" (request_with_body "POST" "/items" {|{"id":7,"name":"x"}|}) 201;
  check rt svc "POST /items (conflict)" (request_with_body "POST" "/items" {|{"id":7,"name":"y"}|}) 409;
  check rt svc "POST /items (bad body)" (request_with_body "POST" "/items" {|nope|}) 400;
  check rt svc "PUT /items/7 (405)" (request ~meth:"PUT" "/items/7") 405;
  check rt svc "GET /nope (404)" (request "/nope") 404;
  print_endline "p2_extractors: all assertions passed"
