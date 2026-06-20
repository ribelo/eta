type t = {
  meth : string;
  scheme : string;
  authority : string option;
  path : string;
  headers : Headers.t;
}

val create : ?scheme:string -> ?headers:Headers.t -> string -> string -> t
