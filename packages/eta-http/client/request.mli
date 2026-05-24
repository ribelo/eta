(** Public eta-http request model. *)

type body =
  | Empty
  | Fixed of bytes list
  | Stream of Eta_http_body.Stream.t
  | Rewindable_stream of {
      length : int option;
      make : unit -> Eta_http_body.Stream.t;
    }

type t = {
  method_ : string;
  uri : string;
  headers : Eta_http_core.Header.t;
  body : body;
}

val make :
  ?headers:Eta_http_core.Header.t -> ?body:body -> string -> string -> t

val body_chunks : t -> int
val body_source : body -> Eta_http_body.Source.t
val method_value : t -> Eta_http_core.Method.t
val url : t -> Eta_http_core.Url.t
