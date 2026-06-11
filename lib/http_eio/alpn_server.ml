(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type unsupported = { protocol : string }

let dispatch ~close ~use_h1 ~use_h2 alpn =
  match Eta_http.Transport.Dispatch.decide_alpn alpn with
  | Ok Eta_http.Transport.Dispatch.Use_h1 -> Ok (use_h1 ())
  | Ok Eta_http.Transport.Dispatch.Use_h2 -> Ok (use_h2 ())
  | Error protocol ->
      close ();
      Error { protocol }
