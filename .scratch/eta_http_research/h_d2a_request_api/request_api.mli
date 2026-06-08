open Eta

type error = Error.t
type protocol = H1 | H2
type headers = (string * string) list

module Stream : sig
  type t

  val read : t -> (string option, error) Effect.t
  val read_all : t -> (string, error) Effect.t
  val discard : t -> (unit, error) Effect.t
end

module Request : sig
  type body = Empty | Fixed of string list

  type t = {
    method_ : string;
    uri : string;
    headers : headers;
    body : body;
  }

  val make : ?headers:headers -> ?body:body -> string -> string -> t
  val body_chunks : t -> int
end

module Response : sig
  type t = {
    status : int;
    headers : headers;
    body : Stream.t;
    trailers : unit -> (headers, error) Effect.t;
  }
end

module Stats : sig
  type t = {
    protocol : protocol;
    active : int;
    idle : int;
    capacity : int;
    opened : int;
    released : int;
    raw : string list;
  }

  val protocol_to_string : protocol -> string
  val to_lines : t -> string list
end

module Client : sig
  type t

  val protocol : t -> protocol
  val stats : t -> (Stats.t, error) Effect.t
  val shutdown : t -> (unit, error) Effect.t
end

val request : Client.t -> Request.t -> (Response.t, error) Effect.t

module Private : sig
  type response_plan = {
    status : int;
    headers : headers;
    chunks : string list;
    trailers : headers;
    delay_per_chunk : Duration.t option;
  }

  val make_client :
    protocol:protocol ->
    request:(Request.t -> (Response.t, error) Effect.t) ->
    stats:(unit -> (Stats.t, error) Effect.t) ->
    shutdown:(unit -> (unit, error) Effect.t) ->
    Client.t

  val make_stream :
    ?delay_per_chunk:Duration.t ->
    release:(unit -> (unit, error) Effect.t) ->
    string list ->
    Stream.t

  val response_plan : Request.t -> response_plan
  val error : protocol -> Request.t -> Error.kind -> error
end
