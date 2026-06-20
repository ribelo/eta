(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type unsupported = { protocol : string }

let dispatch ~enabled_protocols ~close ~use_h1 ~use_h2 alpn =
  match
    Dispatch.decide_alpn ~enabled_protocols alpn
  with
  | Ok Dispatch.Use_h1 -> Ok (use_h1 ())
  | Ok Dispatch.Use_h2 -> Ok (use_h2 ())
  | Error error ->
      close ();
      Error
        {
          protocol =
            Dispatch.alpn_error_to_string error;
        }
