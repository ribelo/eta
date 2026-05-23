(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t = {
  status : int;
  headers : Eta_http_core.Header.t;
  body : Eta_http_body.Stream.t;
  trailers : unit -> (Eta_http_core.Header.t, Eta_http_error.Error.t) Eta.Effect.t;
}

let make ?(headers = Eta_http_core.Header.empty)
    ?(trailers = fun () -> Eta.Effect.pure Eta_http_core.Header.empty) ~status
    ~body () =
  { status; headers; body; trailers }
