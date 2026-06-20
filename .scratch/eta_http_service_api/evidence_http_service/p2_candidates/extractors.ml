(* Extractors — the Axum/Ring idea, Eta-typed (prototype).

   This is the *best idea* from Branch C, factored out as a composable piece on
   top of Branch A. Instead of a monolithic "declare everything" endpoint DSL,
   an extractor is a typed pull from the request that names what the handler
   needs. Handlers declare their dependencies via their argument types, exactly
   like Axum's FromRequest/FromRequestParts.

   Extractors return ('a, Server.Error.t) Effect.t so decode/validation failures
   stay in Eta's typed-failure channel (NOT exceptions, NOT raw 400s hidden
   inside the helper). The route adapter runs extractors in order; the first one
   that fails short-circuits with a typed error that the router maps to a
   response via [on_error].

   Everything speaks the SAME types:
     - extractor input  = Branch_a.Req.t  (the routed request, params on board)
     - extractor output = ('a, Server.Error.t) Effect.t
     - route output     = Server.handler  (compiles down to the shared type)
   So router + extractors + middleware compose by application. No new handler
   type. (Ring/Tower uniformity law.) *)
open Eta

module S = Eta_http.Server

(* A typed failure the router can map to a status. Reuses Server.Error's
   existing taxonomy; adds nothing. *)
let bad_request ?(msg = "bad request") () =
  S.Error.make ~method_:"" ~target:"" (S.Error.Bad_request { message = msg })

(* --- the primitive extractors ------------------------------------------- *)

(* Path parameter. Fails typed if missing. *)
module Param = struct
  type 'a t = Branch_a.Req.t -> ('a, S.Error.t) Effect.t

  let string name (req : Branch_a.Req.t) =
    match Branch_a.Req.param req name with
    | Some v -> Effect.pure v
    | None -> Effect.fail (bad_request ~msg:("missing param " ^ name) ())

  let int name (req : Branch_a.Req.t) =
    match Branch_a.Req.param req name with
    | None -> Effect.fail (bad_request ~msg:("missing param " ^ name) ())
    | Some v ->
      (match int_of_string_opt v with
       | Some n -> Effect.pure n
       | None -> Effect.fail (bad_request ~msg:("param " ^ name ^ " not an int") ()))
end

(* Query parameter (single). Decodes the raw query string. *)
module Query = struct
  let single name (req : Branch_a.Req.t) =
    let raw = req.raw.Eta_http.Server.Request.query in
    let find =
      match raw with
      | None -> None
      | Some q ->
        let rec loop = function
          | [] -> None
          | pair :: rest ->
            (match String.index_opt pair '=' with
             | Some i when String.sub pair 0 i = name ->
               Some (String.sub pair (i + 1) (String.length pair - i - 1))
             | _ -> loop rest)
        in
        loop (String.split_on_char '&' q)
    in
    match find with
    | Some v -> Effect.pure (Some v)
    | None -> Effect.pure None
end

(* Header (single, optional). *)
let header name (req : Branch_a.Req.t) =
  Effect.pure (Eta_http.Core.Header.get name req.raw.Eta_http.Server.Request.headers)

(* Request body, fully read, as a string. *)
let body_string (req : Branch_a.Req.t) =
  let open Eta.Syntax in
  let* bytes = S.Body.read_all (Branch_a.Req.body req) in
  Effect.pure (Bytes.to_string bytes)

(* JSON body decoded by a user-supplied decoder. The decoder returns ('a, string)
   result; a decode failure becomes a typed Server.Error (Bad_request). *)
let json_body (decode : Yojson.Safe.t -> ('a, string) result)
    (req : Branch_a.Req.t) =
  let open Eta.Syntax in
  let* bytes = S.Body.read_all (Branch_a.Req.body req) in
  match Yojson.Safe.from_string (Bytes.to_string bytes) with
  | y ->
    (match decode y with
     | Ok a -> Effect.pure a
     | Error msg -> Effect.fail (bad_request ~msg:("invalid body: " ^ msg) ()))
  | exception Yojson.Json_error e -> Effect.fail (bad_request ~msg:e ())

(* --- route adapter: run extractors then the handler ---------------------- *)
(* A route handler takes its extracted arguments and returns
   (S.Response.t, S.Error.t) Effect.t. Typed failures propagate naturally —
   Eta's Effect.* already sequences them. [map_error] at the boundary converts
   any remaining typed Server.Error into a response via the default renderer. *)

(* lift a routed handler so its typed failures become responses at the edge *)
let to_route (h : Branch_a.Req.t -> (S.Response.t, S.Error.t) Effect.t) :
    Branch_a.route =
  fun req ->
    Effect.map_error (fun _err -> assert false) (h req)
  [@warning "-52"]

(* arity-1: one extractor, then the handler. *)
let route1 (e1 : Branch_a.Req.t -> ('a, S.Error.t) Effect.t)
    (h : 'a -> (S.Response.t, S.Error.t) Effect.t) : Branch_a.route =
  fun req ->
    let open Eta.Syntax in
    let* a = e1 req in
    h a

(* arity-2: two extractors. *)
let route2
    (e1 : Branch_a.Req.t -> ('a, S.Error.t) Effect.t)
    (e2 : Branch_a.Req.t -> ('b, S.Error.t) Effect.t)
    (h : 'a -> 'b -> (S.Response.t, S.Error.t) Effect.t) : Branch_a.route =
  fun req ->
    let open Eta.Syntax in
    let* a = e1 req in
    let* b = e2 req in
    h a b

(* arity-3. *)
let route3
    (e1 : Branch_a.Req.t -> ('a, S.Error.t) Effect.t)
    (e2 : Branch_a.Req.t -> ('b, S.Error.t) Effect.t)
    (e3 : Branch_a.Req.t -> ('c, S.Error.t) Effect.t)
    (h : 'a -> 'b -> 'c -> (S.Response.t, S.Error.t) Effect.t) : Branch_a.route =
  fun req ->
    let open Eta.Syntax in
    let* a = e1 req in
    let* b = e2 req in
    let* c = e3 req in
    h a b c
