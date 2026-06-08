open Fixture

let name = "H-S0 skip entirely"

let recommended_stack =
  [
    ("ppx_yojson_conv", "record/variant JSON codecs generated from OCaml types");
    ("decoders", "combinator decoders for JSON-like values and structured errors");
    ("data-encoding", "bidirectional JSON/binary encodings with schema-like values");
    ("ppx_deriving_jsonschema", "JSON Schema generation from OCaml types");
    ("atd", "schema-first IDL that generates OCaml JSON readers and writers");
    ("ppx_repr/repr", "type representations for equality, generation, and encodings");
  ]

let support = no_support

let notes =
  "No Effet API. Users wrap library results with Effect.pure/Effect.fail at the boundary."

module type SKIP_SIG = sig
  val name : string
  val recommended_stack : (string * string) list
  val support : Fixture.support
  val notes : string
end

module _ : SKIP_SIG = struct
  let name = name
  let recommended_stack = recommended_stack
  let support = support
  let notes = notes
end
