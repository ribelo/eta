(** Backend-neutral HTTP server response model. *)

module Body : sig
  type stream = {
    read : unit -> (bytes option, Server_error.t) Eta.Effect.t;
    release : unit -> (unit, Server_error.t) Eta.Effect.t;
  }

  type t =
    | Empty
    | Fixed of bytes list
    | Stream of stream

  val empty : t
  val fixed : bytes list -> t
  val string : string -> t

  val stream :
    ?release:(unit -> (unit, Server_error.t) Eta.Effect.t) ->
    (unit -> (bytes option, Server_error.t) Eta.Effect.t) ->
    t
end

type t

val make :
  ?headers:Header.t ->
  ?trailers:(unit -> (Header.t, Server_error.t) Eta.Effect.t) ->
  status:int ->
  body:Body.t ->
  unit ->
  t

val empty :
  ?headers:Header.t ->
  status:int ->
  unit ->
  t

val text :
  ?headers:Header.t ->
  ?status:int ->
  string ->
  t

val status : t -> int
val headers : t -> Header.t
val body : t -> Body.t
val trailers : t -> unit -> (Header.t, Server_error.t) Eta.Effect.t
