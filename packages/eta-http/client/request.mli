(** Public eta-http request model. *)

type body = Empty | Fixed of bytes list

type t = {
  method_ : string;
  uri : string;
  headers : Eta_http_core.Header.t;
  body : body;
}

val make :
  ?headers:Eta_http_core.Header.t -> ?body:body -> string -> string -> t

val body_chunks : t -> int
val method_value : t -> Eta_http_core.Method.t
val url : t -> Eta_http_core.Url.t
