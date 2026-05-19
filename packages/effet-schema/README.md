# effet-schema

`effet-schema` is a companion package for Effet applications that need a
contract layer similar to Effect Schema, shaped for OCaml.

The core value is pure:

```ocaml
type 'a Effet_schema.Schema.t
```

A schema can decode JSON, encode values, expose JSON Schema metadata, provide
sample values, and derive equality. It does not carry an Effet environment.
Effectful validation belongs at the decode boundary through
`Schema.decode_with_policy`, so service requirements remain normal Effet
object-row requirements.

Recommended application style is module-first: domain modules expose `type t`,
`val schema`, `val decode`, `val encode`, and `val equal`.

Validated nominal values are ordinary OCaml domain types built with
`Schema.transform`, not a public TypeScript-style wrapper:

```ocaml
module User_id : sig
  type t = private string
  val schema : t Effet_schema.Schema.t
  val value : t -> string
  val equal : t -> t -> bool
end = struct
  type t = string

  let value s = s
  let equal = String.equal

  let schema =
    Effet_schema.Schema.transform ~name:"user_id"
      ~decode:(fun s ->
        if String.starts_with ~prefix:"usr_" s then Ok s
        else Error [ Effet_schema.issue "Expected user_id" ])
      ~encode:value
      ~equal
      Effet_schema.Schema.string
end
```
