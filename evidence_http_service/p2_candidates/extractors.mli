(** Extractors — Axum/Ring-style typed request pulls (public API sketch).

    The recommended v1 [Eta_http_service.Extractors] surface. An extractor is a
    typed pull from a routed [Branch_a.Req.t]; handlers declare their
    dependencies as extractor arguments. Decode/validation failures stay in
    Eta's typed-failure channel (the server renders [Bad_request] -> 400).
    See [docs/research/eta-http-service-api.md]. *)

open Eta

(** Path parameters. *)
module Param : sig
  val string : string -> Branch_a.Req.t -> (string, Eta_http.Server.Error.t) Effect.t
  val int : string -> Branch_a.Req.t -> (int, Eta_http.Server.Error.t) Effect.t
end

(** Query string (single value, optional). *)
module Query : sig
  val single : string -> Branch_a.Req.t -> (string option, Eta_http.Server.Error.t) Effect.t
end

val header : string -> Branch_a.Req.t -> (string option, Eta_http.Server.Error.t) Effect.t
val body_string : Branch_a.Req.t -> (string, Eta_http.Server.Error.t) Effect.t

val json_body :
  (Yojson.Safe.t -> ('a, string) result) ->
  Branch_a.Req.t ->
  ('a, Eta_http.Server.Error.t) Effect.t
(** [json_body decode req] reads the body, parses JSON, and runs [decode].
    A parse or decode failure becomes a typed [Bad_request]. *)

(** Route adapters: run extractors in order, then the handler. The first
    extractor that fails short-circuits with a typed error. Arity 1/2/3;
    extend as needed. *)
val route1 :
  (Branch_a.Req.t -> ('a, Eta_http.Server.Error.t) Effect.t) ->
  ('a -> (Eta_http.Server.Response.t, Eta_http.Server.Error.t) Effect.t) ->
  Branch_a.route

val route2 :
  (Branch_a.Req.t -> ('a, Eta_http.Server.Error.t) Effect.t) ->
  (Branch_a.Req.t -> ('b, Eta_http.Server.Error.t) Effect.t) ->
  ('a -> 'b -> (Eta_http.Server.Response.t, Eta_http.Server.Error.t) Effect.t) ->
  Branch_a.route

val route3 :
  (Branch_a.Req.t -> ('a, Eta_http.Server.Error.t) Effect.t) ->
  (Branch_a.Req.t -> ('b, Eta_http.Server.Error.t) Effect.t) ->
  (Branch_a.Req.t -> ('c, Eta_http.Server.Error.t) Effect.t) ->
  ('a -> 'b -> 'c -> (Eta_http.Server.Response.t, Eta_http.Server.Error.t) Effect.t) ->
  Branch_a.route
