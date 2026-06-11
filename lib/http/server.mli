(** Backend-neutral HTTP server surface. *)

module Error = Server_error
module Body = Server_body
module Config = Server_config
module Request = Server_request
module Response = Server_response

type handler = Request.t -> (Response.t, Error.t) Eta.Effect.t

module Handler : sig
  val map_error :
    ('err -> Error.t) ->
    (Request.t -> (Response.t, 'err) Eta.Effect.t) ->
    handler

  val with_default_error_response :
    ?renderer:(Error.t -> Response.t) ->
    handler ->
    handler

  val default_error_response : Error.t -> Response.t
  val route_not_found : handler
end
