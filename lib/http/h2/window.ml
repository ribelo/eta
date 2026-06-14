(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t = { mutable avail : int }

let create ~initial = { avail = initial }
let available t = t.avail

let consume t n =
  if n < 0 then Error Error_code.Flow_control_error
  else if t.avail < n then Error Error_code.Flow_control_error
  else (t.avail <- t.avail - n; Ok ())

let update t n =
  let next = t.avail + n in
  if next > 0x7fffffff then Error Error_code.Flow_control_error
  else (t.avail <- next; Ok ())
