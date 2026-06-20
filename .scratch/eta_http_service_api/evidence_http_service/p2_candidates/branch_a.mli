(** Branch A — Minimal Service Adapter (router bridge): public API sketch.

    This is the recommended v1 [Eta_http_service.Router] surface. It adapts the
    existing [Eta_router] radix trie to the [Eta_http.Server.handler] contract,
    adding method dispatch + 404 + 405. See
    [docs/research/eta-http-service-api.md]. *)

open Eta

module Req : sig
  (** A routed request: the original [Server.Request.t] plus matched params. *)

  type t = {
    raw : Eta_http.Server.Request.t;
    params : Eta_router.Params.t;
  }

  val param : t -> string -> string option
  val path : t -> string
  val method_ : t -> string
  val header : t -> string -> string option
  val body : t -> Eta_http.Server.Body.t
end

type route = Req.t -> (Eta_http.Server.Response.t, Eta_http.Server.Error.t) Effect.t

type config = {
  not_found : Eta_http.Server.handler;
  method_not_allowed : string -> string -> Eta_http.Server.handler;
}

val default_config : config

type t
(** A mutable router under construction. *)

val create : unit -> t
val add : t -> ?methods:string list -> string -> route -> unit
(** [add t ?methods pattern route] registers [route] for [pattern] under the
    given HTTP methods (default [[ "GET" ]]). Pipe-first:
    [t |> add "/items/{id}" h]. *)

val compile : ?config:config -> t -> Eta_http.Server.handler
(** [compile t] freezes the router into an [Eta_http.Server.handler].
    - unmatched path  -> [config.not_found]            (404 by default)
    - path matched, wrong method -> [config.method_not_allowed]  (405) *)
