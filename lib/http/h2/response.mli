type body = [ `Empty | `String of string | `Reader of Body.Reader.t ]

type t = {
  status : Status.t;
  headers : Headers.t;
  body : body;
  trailers : Headers.t Lazy.t;
}

val create : ?headers:Headers.t -> status:Status.t -> body -> t
