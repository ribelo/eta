(* Branch C — Typed Endpoint Builder (prototype, the high-effort candidate).

   Per the evidence rules, this candidate gets a FAIR probe: it builds the same
   inn-shaped spec as Branch A, with its strongest version, then is judged.

   Design: declare method + path + body decoder + response encoder together,
   producing an Eta_http.Server.handler. The "typed" part: the handler you
   write receives the ALREADY-DECODED request body (and params), and returns a
   domain value (Yojson here) that the framework encodes to a 200 response.
   Domain errors are typed failures whose payload is the short-circuit response.

   Steelman for:   removes decode/encode boilerplate at EVERY endpoint.
   Steelman against: can force a schema style / make trivial handlers noisier.
   The probe shows whether the cost is paid back. *)
open Eta

module S = Eta_http.Server
module R = Eta_router

let json ?(status = 200) yo =
  let h =
    Eta_http.Core.Header.unsafe_add "content-type" "application/json"
      Eta_http.Core.Header.empty
  in
  S.Response.make ~status ~body:(S.Response.Body.string (Yojson.Safe.to_string yo))
    ~headers:h ()

(* The endpoint descriptor. decode_req is the final handler for that route. *)
type 'req endpoint = {
  method_ : string;
  pattern : string;
  decode_req : S.Request.t -> R.Params.t -> (S.Response.t, S.Error.t) Effect.t;
}

(* POST endpoint with a declared body decoder. The handler receives a decoded
   ['req], returns (resp, Response) Effect.t where success carries
   (status, Yojson) so it can express 201/204 etc.; typed failure Response is a
   short-circuit response. *)
let body_json
    ?(method_ = "POST")
    ~pattern
    ~(decode_json : Yojson.Safe.t -> ('req, string) result)
    ~(handle : 'req -> ((int * Yojson.Safe.t), S.Response.t) Effect.t)
    () =
  let runner request _params =
    let open Eta.Syntax in
    let* bytes = S.Body.read_all request.Eta_http.Server.Request.body in
    let parsed =
      match Yojson.Safe.from_string (Bytes.to_string bytes) with
      | j -> j
      | exception Yojson.Json_error _ -> `Null
    in
    match decode_json parsed with
    | Ok req ->
      let* outcome = Effect.result (handle req) in
      (match outcome with
       | Ok (status, yojson) -> Effect.pure (json ~status yojson)
       | Error resp -> Effect.pure resp)
    | Error msg ->
      Effect.pure (json ~status:400 (`Assoc [ ("error", `String msg) ]))
  in
  { method_; pattern; decode_req = runner }

(* GET endpoint with path params, no body. Success carries (status, Yojson). *)
let get
    ~pattern
    ~(handle : R.Params.t -> ((int * Yojson.Safe.t), S.Response.t) Effect.t)
    () =
  let runner _request params =
    let open Eta.Syntax in
    let* outcome = Effect.result (handle params) in
    (match outcome with
     | Ok (status, yojson) -> Effect.pure (json ~status yojson)
     | Error resp -> Effect.pure resp)
  in
  { method_ = "GET"; pattern; decode_req = runner }

(* --- compile endpoints to a handler (router + method dispatch + 404/405) --- *)
type app = {
  endpoints :
    (string * string * (S.Request.t -> R.Params.t -> (S.Response.t, S.Error.t) Effect.t))
    list ref;
}

let create () = { endpoints = ref [] }

let mount (app : app) (e : 'a endpoint) =
  app.endpoints := (e.method_, e.pattern, e.decode_req) :: !(app.endpoints)

let compile (app : app) : S.handler =
  let router :
      (string * (S.Request.t -> R.Params.t -> (S.Response.t, S.Error.t) Effect.t)) list R.Router.t =
    R.Router.create ()
  in
  List.iter
    (fun (m, pattern, runner) ->
      let existing =
        match R.Router.at router pattern with
        | Ok x -> Some x.R.Match.value
        | Error _ -> None
      in
      let merged = (m, runner) :: Option.value existing ~default: [] in
      ignore (R.Router.remove router pattern);
      ignore (R.Router.insert router pattern merged))
    (List.rev !(app.endpoints));
  fun request ->
    let path = request.Eta_http.Server.Request.path in
    match R.Router.at router path with
    | Error R.Error.Not_found -> Effect.pure (json ~status:404 (`String "not found"))
    | Ok { R.Match.value = table; params } ->
        match List.assoc_opt request.Eta_http.Server.Request.method_ table with
        | Some runner -> runner request params
        | None -> Effect.pure (json ~status:405 (`String "method not allowed"))
