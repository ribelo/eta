(** Backend-neutral HTTP server request model. *)

type peer = {
  address : string option;
  port : int option;
}

type t = {
  id : string Lazy.t;
  version : Version.t;
  scheme : string;
  authority : string option;
  method_ : string;
  target : string;
  path : string;
  query : string option;
  headers : Header.t;
  body : Server_body.t;
  trailers : unit -> (Header.t, Server_error.t) Eta.Effect.t;
  peer : peer;
  tls : bool;
  alpn_protocol : string option;
  stream_id : int option;
  connection_id : string;
}

val split_target : string -> string * string option
val header : string -> t -> string option
val body : t -> Server_body.t
val trailers : t -> (Header.t, Server_error.t) Eta.Effect.t
val trace_context : t -> Eta.Trace_context.t option
