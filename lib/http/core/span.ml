(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t : immutable_data = {
  off : int;
  len : int;
}

let make ~off ~len =
  if off < 0 || len < 0 then invalid_arg "Http.Span.make";
  { off; len }

let empty = { off = 0; len = 0 }
let end_offset t = t.off + t.len
