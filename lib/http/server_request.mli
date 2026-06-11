(** Backend-neutral HTTP server request model. *)

type peer = {
  address : string option;
  port : int option;
}

type t = {
  id : string;
  version : Version.t;
  scheme : string;
  authority : string option;
  method_ : string;
  target : string;
  path : string;
  query : string option;
  headers : Header.t;
  body : Server_body.t;
  peer : peer;
  tls : bool;
  alpn_protocol : string option;
  stream_id : int option;
}

val split_target : string -> string * string option
val header : string -> t -> string option
val body : t -> Server_body.t
val trace_context : t -> Eta.Trace_context.t option
