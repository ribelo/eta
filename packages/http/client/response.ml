(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t = {
  status : int;
  headers : Http_core.Header.t;
  body : Http_body.Stream.t;
  trailers : unit -> (Http_core.Header.t, Http_error.Error.t) Eta.Effect.t;
}

let make ?(headers = Http_core.Header.empty)
    ?(trailers = fun () -> Eta.Effect.pure Http_core.Header.empty) ~status
    ~body () =
  { status; headers; body; trailers }
