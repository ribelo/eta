open Eta_schema
open Schema_common

type t = { a : string; b : int; c : bool; d : float; e : string option; f : int }

let schema =
  Eta_schema.record6 ~name:"schema_m01"
    (fun a b c d e f -> { a; b; c; d; e; f })
    (Eta_schema.required "a" non_empty_string (fun r -> r.a))
    (Eta_schema.required "b" positive_int (fun r -> r.b))
    (Eta_schema.required "c" enabled (fun r -> r.c))
    (Eta_schema.required "d" finite_float (fun r -> r.d))
    (Eta_schema.optional "e" Eta_schema.string (fun r -> r.e))
    (Eta_schema.required "f" positive_int (fun r -> r.f))
    ~equal:( = ) ()
