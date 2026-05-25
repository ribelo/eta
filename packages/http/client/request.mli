(** Public eta-http request model. *)

type body =
  | Empty
  | Fixed of bytes list
  | Stream of Http_body.Stream.t
  | Rewindable_stream of {
      length : int option;
      make : unit -> Http_body.Stream.t;
    }

type t = {
  method_ : string;
  uri : string;
  headers : Http_core.Header.t;
  body : body;
}

val make :
  ?headers:Http_core.Header.t -> ?body:body -> string -> string -> t

val body_chunks : t -> int
val body_source : body -> Http_body.Source.t
val method_value : t -> Http_core.Method.t
val url : t -> Http_core.Url.t
