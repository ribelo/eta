(* P1 baseline service 2: JSON request/response + schema decode + domain errors.

   Built using ONLY existing public primitives. This file deliberately exposes
   the friction a microservice author hits today:

     FRICTION 1 — no JSON adapter ships with eta_schema. The user must hand-write
       a [Yojson_adapter : Eta_schema.JSON_ADAPTER] module before any schema
       decode/encode works. (eta_ai uses an internal `ln` adapter; eta_http has
       no Json module.)
     FRICTION 2 — mapping domain errors to specific HTTP statuses is awkward:
       Eta_http.Server.Error has a fixed taxonomy (Bad_request -> 400, ...) but
       no Conflict(409)/Unprocessable(422) kinds, so either you branch and
       return Response.t directly (losing the typed-failure channel) or you
       fight the taxonomy. Below we branch and return Response directly.

   POST /items  -> create item; 201 on success, 400 on schema error, 409 on
   conflict (duplicate id). *)
open Eta

module Server = Eta_http.Server
module Schema = Eta_schema

(* --- FRICTION 1: hand-written yojson adapter ----------------------------- *)
module Yojson_adapter = struct
  type external_json = Yojson.Safe.t

  let rec of_external (j : Yojson.Safe.t) : (Schema.json, Schema.issue list) result =
    let open Schema.Json in
    match j with
    | `Null -> Ok Null
    | `Bool b -> Ok (Bool b)
    | `Int n -> Ok (Number (Int n))
    | `Intlit s -> Ok (Number (Intlit s))
    | `Float f -> Ok (Number (Float f))
    | `String s -> Ok (String s)
    | `Assoc xs ->
        let rec to_obj = function
          | [] -> Ok []
          | (k, v) :: rest ->
              (match of_external v with
               | Error e -> Error e
               | Ok vv -> (match to_obj rest with Ok r -> Ok ((k, vv) :: r) | Error e -> Error e))
        in
        (match to_obj xs with Ok r -> Ok (Object r) | Error e -> Error e)
    | `List xs ->
        let rec to_arr = function
          | [] -> Ok []
          | v :: rest ->
              (match of_external v, to_arr rest with
               | Ok vv, Ok r -> Ok (vv :: r)
               | Error e, _ | _, Error e -> Error e)
        in
        (match to_arr xs with Ok r -> Ok (Array r) | Error e -> Error e)
    | `Tuple _ | `Variant _ -> Error [ Schema.issue "unsupported json variant" ]

  let rec to_external (j : Schema.json) : Yojson.Safe.t =
    let open Schema.Json in
    match j with
    | Null -> `Null
    | Bool b -> `Bool b
    | Number (Int n) -> `Int n
    | Number (Intlit s) -> `Intlit s
    | Number (Float f) -> `Float f
    | String s -> `String s
    | Object xs -> `Assoc (List.map (fun (k, v) -> (k, to_external v)) xs)
    | Array xs -> `List (List.map to_external xs)
end

module C = Schema.Make (Yojson_adapter)

(* --- domain model + schema ---------------------------------------------- *)
type item = { id : int; name : string }

let item_schema : item Schema.Eta_schema.t =
  Schema.Eta_schema.record2 ~name:"item"
    (fun id name -> { id; name })
    (Schema.Eta_schema.required "id" Schema.Eta_schema.int (fun i -> i.id))
    (Schema.Eta_schema.required "name" Schema.Eta_schema.string (fun i -> i.name))
    ~equal:(fun a b -> a.id = b.id && a.name = b.name)
    ()

(* tiny in-memory store, application-owned *)
let store : item list ref = ref []

(* --- response helpers (more friction: no Server.Response.json) ----------- *)
let json status yo =
  let s = Yojson.Safe.to_string yo in
  let h =
    Eta_http.Core.Header.unsafe_add "Content-Type" "application/json"
      Eta_http.Core.Header.empty
  in
  Server.Response.make ~status ~body:(Server.Response.Body.string s) ~headers:h ()

let text status s = Server.Response.text ~status s

(* --- the handler: read body, decode, business logic, map errors ---------- *)
let handler : Server.handler =
  let open Eta.Syntax in
  fun request ->
    if not (String.equal request.Server.Request.method_ "POST"
            && String.equal request.Server.Request.path "/items") then
      Effect.pure (text 404 "not found\n")
    else
      let* body = Server.Body.read_all request.Server.Request.body in
      (* parse yojson (may raise) then schema-decode *)
      let parsed =
        match Yojson.Safe.from_string (Bytes.to_string body) with
        | j -> C.decode_result item_schema j
        | exception Yojson.Json_error m -> Error [ Schema.issue m ]
      in
      match parsed with
      | Error issues -> Effect.pure (json 400 (`Assoc [ ("error", `String (Schema.render_issues issues)) ]))
      | Ok item ->
          (* business rule: duplicate id -> conflict *)
          if List.exists (fun i -> i.id = item.id) !store then
            Effect.pure (text 409 "conflict\n")
          else begin
            store := item :: !store;
            let resp = C.encode_result item_schema item in
            match resp with
            | Ok y -> Effect.pure (json 201 y)
            | Error _ -> Effect.pure (text 500 "encode error\n")
          end

(* --------------------------------------------------------------------- *)
(* Handler-only test: synthetic Request.t with a body, no socket. *)

let request_with_body meth path body_str =
  let body =
    let consumed = ref false in
    Server.Body.of_reader
      (fun () ->
        if !consumed then Effect.pure None
        else begin
          consumed := true;
          if String.length body_str = 0 then Effect.pure None
          else Effect.pure (Some (Bytes.of_string body_str))
        end)
  in
  {
    Server.Request.id = lazy "p1b";
    version = Eta_http.Core.Version.H1_1;
    scheme = "http";
    authority = Some "localhost";
    method_ = meth;
    target = path;
    path;
    query = None;
    headers = Eta_http.Core.Header.empty;
    body;
    trailers = (fun () -> Effect.pure Eta_http.Core.Header.empty);
    peer = { address = Some "127.0.0.1"; port = Some 8080 };
    tls = false;
    alpn_protocol = None;
    stream_id = None;
    connection_id = "p1b-conn";
  }

let status_of rt body_str expected =
  match Eta_eio.Runtime.run rt (handler (request_with_body "POST" "/items" body_str)) with
  | Exit.Ok resp ->
      let s = Server.Response.status resp in
      if s = expected then Printf.printf "[PASS] status %d (expected %d)\n" s expected
      else failwith (Printf.sprintf "[FAIL] expected %d, got %d" expected s)
  | Exit.Error cause ->
      let buf = Buffer.create 64 in
      Format.fprintf (Format.formatter_of_buffer buf) "%a"
        (Cause.pp Server.Error.pp) cause;
      failwith (Printf.sprintf "[FAIL] effect error: %s" (Buffer.contents buf))

let () =
  store := [];
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  status_of rt {|{"id":1,"name":"widget"}|} 201;   (* created *)
  status_of rt {|{"id":1,"name":"dup"}|} 409;       (* conflict *)
  status_of rt {|{"id":"oops"}|} 400;               (* schema error *)
  status_of rt {|not json|} 400;                     (* bad json *)
  print_endline "p1b_json: all handler-only assertions passed"
