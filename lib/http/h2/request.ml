type t = {
  meth : string;
  scheme : string;
  authority : string option;
  path : string;
  headers : Headers.t;
}

let create ?(scheme = "http") ?(headers = Headers.empty) meth path =
  { meth; scheme; authority = None; path; headers }
