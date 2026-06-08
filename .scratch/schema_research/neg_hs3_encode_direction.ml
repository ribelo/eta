(* Property: H-S3 transformations keep the decoded input type for encode.
   Predicted: finite_from_string encodes floats, not strings. *)

let bad =
  H_s3_schema_gadt.Schema.encode
    H_s3_schema_gadt.finite_from_string
    "1.5"
