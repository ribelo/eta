open Eta_schema

let positive_int =
  Eta_schema.refine ~name:"positive_int"
    (fun n -> if n >= 0 then [] else [ issue "expected non-negative int" ])
    Eta_schema.int

let non_empty_string =
  Eta_schema.refine ~name:"non_empty_string"
    (fun s -> if String.length s > 0 then [] else [ issue "expected non-empty string" ])
    Eta_schema.string

let finite_float =
  Eta_schema.refine ~name:"finite_float"
    (fun f -> if Float.is_finite f then [] else [ issue "expected finite float" ])
    Eta_schema.float

let enabled = Eta_schema.bool
