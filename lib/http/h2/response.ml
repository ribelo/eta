type body = [ `Empty | `String of string | `Reader of Body.Reader.t ]

type t = {
  status : Status.t;
  headers : Headers.t;
  body : body;
  trailers : Headers.t Lazy.t;
}

let create ?(headers = Headers.empty) ~status body =
  { status; headers; body; trailers = Lazy.from_val [] }
