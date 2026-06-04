(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t = {
  status : int;
  headers : Header.t;
  body : Stream.t;
  trailers : (unit -> (Header.t, Error.t) Eta.Effect.t) @@ many;
}

let make ?(headers = Header.empty)
    ?(trailers @ many = fun () -> Eta.Effect.pure Header.empty) ~status
    ~body () =
  { status; headers; body; trailers }
