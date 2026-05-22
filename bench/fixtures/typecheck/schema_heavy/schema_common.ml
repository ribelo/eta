open Eta_schema

let positive_int =
  Schema.refine ~name:"positive_int"
    (fun n -> if n >= 0 then [] else [ issue "expected non-negative int" ])
    Schema.int

let non_empty_string =
  Schema.refine ~name:"non_empty_string"
    (fun s -> if String.length s > 0 then [] else [ issue "expected non-empty string" ])
    Schema.string

let finite_float =
  Schema.refine ~name:"finite_float"
    (fun f -> if Float.is_finite f then [] else [ issue "expected finite float" ])
    Schema.float

let enabled = Schema.bool
