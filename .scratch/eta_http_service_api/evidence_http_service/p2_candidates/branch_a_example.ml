(* Branch A — usage example + assertions on the inn-shaped spec.

   This is the "first 15 minutes" example: what a new Eta user writes. Compare
   the call-site LOC here to inn's hand-written match arms (R1) and its 21
   require_method sites (R2). *)
open Eta

module S = Eta_http.Server

(* ---- JSON helper (the same one every branch needs; Branch A does not own it) *)
let json ?(status = 200) yo =
  let h =
    Eta_http.Core.Header.unsafe_add "content-type" "application/json"
      Eta_http.Core.Header.empty
  in
  S.Response.make ~status ~body:(S.Response.Body.string (Yojson.Safe.to_string yo))
    ~headers:h ()

(* ---- the service: 5 routes express the whole spec ---- *)
let store : (int * string) list ref = ref []

let service () : S.handler =
  let t = Branch_a.create () in
  Branch_a.add t "/health" (fun _req -> Effect.pure (S.Response.text ~status:200 "ok"));
  Branch_a.add t "/items/{id}"
    (fun req ->
      match Branch_a.Req.param req "id" with
      | None -> Effect.pure (S.Response.text ~status:400 "missing id\n")
      | Some id_s ->
        (match int_of_string_opt id_s with
         | None -> Effect.pure (json ~status:400 (`Assoc [ ("error", `String "bad id") ]))
         | Some id ->
           let name = "widget-" ^ string_of_int id in
           Effect.pure (json (`Assoc [ ("id", `Int id); ("name", `String name) ]))));
  Branch_a.add t ~methods:[ "POST" ] "/items"
    (fun req ->
      let open Eta.Syntax in
      let* body = S.Body.read_all (Branch_a.Req.body req) in
      let parsed =
        match Yojson.Safe.from_string (Bytes.to_string body) with
        | `Assoc fields as j -> j
        | exception Yojson.Json_error _ -> `Null
        | _ -> `Null
      in
      match parsed with
      | `Assoc fields ->
        (match List.assoc_opt "id" fields, List.assoc_opt "name" fields with
         | Some (`Int id), Some (`String name) ->
           if List.mem_assoc id !store then
             Effect.pure (S.Response.text ~status:409 "conflict\n")
           else begin
             store := (id, name) :: !store;
             Effect.pure
               (json ~status:201 (`Assoc [ ("id", `Int id); ("name", `String name) ]))
           end
         | _ -> Effect.pure (json ~status:400 (`Assoc [ ("error", `String "bad body") ])))
      | _ -> Effect.pure (json ~status:400 (`Assoc [ ("error", `String "invalid json") ])));
  Branch_a.compile t

(* ---- handler-only assertions (no socket) ---- *)
let request ?(meth = "GET") path =
  {
    S.Request.id = lazy "p2a";
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
    connection_id = "p2a-conn";
  }

let request_with_body meth path body_str =
  let consumed = ref false in
  let body =
    S.Body.of_reader (fun () ->
      if !consumed then Effect.pure None
      else begin consumed := true; Effect.pure (Some (Bytes.of_string body_str)) end)
  in
  { (request ~meth path) with body }

let check rt svc label req expected =
  match Eta_eio.Runtime.run rt (svc req) with
  | Exit.Ok resp ->
    let s = S.Response.status resp in
    if s = expected then Printf.printf "[PASS A] %-34s %d\n" label s
    else failwith (Printf.sprintf "[FAIL A] %s: expected %d got %d" label expected s)
  | Exit.Error cause ->
    let buf = Buffer.create 64 in
    Format.fprintf (Format.formatter_of_buffer buf) "%a" (Cause.pp S.Error.pp) cause;
    failwith (Printf.sprintf "[FAIL A] %s error: %s" label (Buffer.contents buf))

let () =
  store := [];
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let svc = service () in
  check rt svc "GET /health" (request "/health") 200;
  check rt svc "GET /items/7" (request "/items/7") 200;
  check rt svc "POST /items (create)" (request_with_body "POST" "/items" {|{"id":7,"name":"x"}|}) 201;
  check rt svc "POST /items (conflict)" (request_with_body "POST" "/items" {|{"id":7,"name":"y"}|}) 409;
  check rt svc "POST /items (bad body)" (request_with_body "POST" "/items" {|nope|}) 400;
  check rt svc "PUT /items/7 (405)" (request ~meth:"PUT" "/items/7") 405;
  check rt svc "GET /nope (404)" (request "/nope") 404;
  print_endline "p2_branch_a: all assertions passed"
