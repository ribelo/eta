(** Public eta-http request model. *)

type body =
  | Empty
  | Fixed of bytes list
  | Stream of Stream.t
  | Rewindable_stream of {
      length : int option;
      make : (unit -> Stream.t);
    }

type t = {
  method_ : string;
  uri : string;
  headers : Header.t;
  body : body;
}

val make :
  ?headers:Header.t -> ?body:body -> string -> string -> t

val body_chunks : t -> int
val body_source : body -> Source.t
val method_value : t -> Method.t
val url : t -> Url.t
