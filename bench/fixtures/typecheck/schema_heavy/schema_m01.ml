open Eta_schema
open Schema_common

type t = { a : string; b : int; c : bool; d : float; e : string option; f : int }

let schema =
  Schema.record6 ~name:"schema_m01"
    (fun a b c d e f -> { a; b; c; d; e; f })
    (Schema.required "a" non_empty_string (fun r -> r.a))
    (Schema.required "b" positive_int (fun r -> r.b))
    (Schema.required "c" enabled (fun r -> r.c))
    (Schema.required "d" finite_float (fun r -> r.d))
    (Schema.optional "e" Schema.string (fun r -> r.e))
    (Schema.required "f" positive_int (fun r -> r.f))
    ~equal:( = ) ()
