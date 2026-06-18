(* Branch C — usage example + assertions on the inn-shaped spec.

   Same contract as Branch A, so call-site LOC is directly comparable. The
   question this probe answers: does declaring decode/encode together pay back
   its ceremony for the simplest handlers, or does it force a schema style and
   make trivial endpoints harder to read? *)
open Eta

module S = Eta_http.Server

let store : (int * string) list ref = ref []

(* domain types + tiny decoders (NOT eta_schema here; plain result, to test
   whether Branch C forces eta_schema. It does not — decoders are plain fns.) *)
type item = { id : int; name : string }

let decode_item = function
  | `Assoc fields ->
    (match List.assoc_opt "id" fields, List.assoc_opt "name" fields with
     | Some (`Int id), Some (`String name) -> Ok { id; name }
     | _ -> Error "expected {id,name}")
  | _ -> Error "expected object"

let service () : S.handler =
  let app = Branch_c.create () in
  (* GET /health — trivial handler. Note it still goes through the endpoint
     declaration machinery. Is that acceptable ceremony, or too much? *)
  Branch_c.mount app
    (Branch_c.get ~pattern:"/health"
       ~handle:(fun _params -> Effect.pure (200, `String "ok")) ());
  (* GET /items/{id} — param route, returns JSON *)
  Branch_c.mount app
    (Branch_c.get ~pattern:"/items/{id}"
       ~handle:(fun params ->
         match Eta_router.Params.get params "id" with
         | Some id_s ->
           (match int_of_string_opt id_s with
            | Some id ->
              Effect.pure
                (200, `Assoc [ ("id", `Int id); ("name", `String ("widget-" ^ id_s)) ])
            | None -> Effect.fail (Branch_c.json ~status:400 (`String "bad id")))
         | None -> Effect.fail (Branch_c.json ~status:400 (`String "missing id")))
       ());
  (* POST /items — declared body decoder; handler gets a decoded [item] *)
  Branch_c.mount app
    (Branch_c.body_json ~pattern:"/items" ~decode_json:decode_item
       ~handle:(fun (item : item) ->
         if List.mem_assoc item.id !store then
           Effect.fail (Branch_c.json ~status:409 (`String "conflict"))
         else begin
           store := (item.id, item.name) :: !store;
           Effect.pure
             (201, `Assoc [ ("id", `Int item.id); ("name", `String item.name) ])
         end)
       ());
  Branch_c.compile app

module R = Eta_router

let request ?(meth = "GET") path =
  {
    S.Request.id = lazy "p2c";
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
    connection_id = "p2c-conn";
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
    if s = expected then Printf.printf "[PASS C] %-34s %d\n" label s
    else failwith (Printf.sprintf "[FAIL C] %s: expected %d got %d" label expected s)
  | Exit.Error cause ->
    let buf = Buffer.create 64 in
    Format.fprintf (Format.formatter_of_buffer buf) "%a" (Cause.pp S.Error.pp) cause;
    failwith (Printf.sprintf "[FAIL C] %s error: %s" label (Buffer.contents buf))

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
  print_endline "p2_branch_c: all assertions passed"
