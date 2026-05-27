(** Structured error projections. *)

val to_json : Error.t -> string
(** Render a compact JSON object with redacted headers, redacted URL query, and
    omitted body. *)
