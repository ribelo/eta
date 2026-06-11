(** Handler helpers for eta-http servers. *)

type t = Server_request.t -> (Server_response.t, Server_error.t) Eta.Effect.t

val map_error :
  ('err -> Server_error.t) ->
  (Server_request.t -> (Server_response.t, 'err) Eta.Effect.t) ->
  t

val with_default_error_response :
  ?renderer:(Server_error.t -> Server_response.t) ->
  t ->
  t

val default_error_response : Server_error.t -> Server_response.t
val route_not_found : t
