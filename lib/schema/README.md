# eta_schema

`eta_schema` is a companion package for Eta applications that need a
contract layer similar to Effect Eta_schema, shaped for OCaml.

## Package boundary

- `eta_schema` depends on `eta` only.
- It does not depend on Yojson, Ezjsonm, or any concrete JSON library.
- Concrete JSON adapters plug in through `JSON_ADAPTER` and `Make`.
- `eta_schema_test` is a separate test-only package.

The core value is pure:

```ocaml
type 'a Eta_schema.Eta_schema.t
```

A schema can decode JSON, encode values, and derive equality. It does not carry
an Eta environment. Decode and encode failures are typed Eta failures
through `Eta_schema.decode` and `Eta_schema.encode`; direct callers can use
`decode_result` / `encode_result`. Effectful validation belongs at the decode
boundary through `Eta_schema.decode_with_policy`, so service requirements remain
ordinary OCaml arguments or captured values.

The built-in JSON representation preserves number shape:

```ocaml
type number =
  | Int of int
  | Intlit of string
  | Float of float
```

Use `Json.intlit` for integer tokens that do not fit OCaml `int` or must not
round through IEEE 754. `Eta_schema.int` only accepts values that fit OCaml `int`;
`Eta_schema.float` accepts finite numeric tokens.

Recommended application style is module-first: domain modules expose `type t`,
`val schema`, `val decode`, `val encode`, and `val equal`.

Validated nominal values are ordinary OCaml domain types built with
`Eta_schema.transform`, not a public TypeScript-style wrapper:

```ocaml
module User_id : sig
  type t = private string
  val schema : t Eta_schema.Eta_schema.t
  val value : t -> string
  val equal : t -> t -> bool
end = struct
  type t = string

  let value s = s
  let equal = String.equal

  let schema =
    Eta_schema.Eta_schema.transform ~name:"user_id"
      ~decode:(fun s ->
        if String.starts_with ~prefix:"usr_" s then Ok s
        else Error [ Eta_schema.issue "Expected user_id" ])
      ~encode:value
      ~equal
      Eta_schema.Eta_schema.string
end
```

`Eta_schema.transform` requires `~equal`. There is no polymorphic equality
default because transformed values can be abstract, functional, cyclic, or
otherwise unsafe for `Stdlib.( = )`.

Policies may enrich decoded input into a different output type:

```ocaml
type input = { id : User_id.t }
type user = { id : User_id.t; name : string }

let decode_user json =
  let lookup_user id = User_directory.lookup id in
  Eta_schema.Eta_schema.decode_with_policy input_schema
    (fun input ->
      Eta.Effect.map
        (fun name -> { id = input.id; name })
        (Eta.Effect.named "lookup-user" (Eta.Effect.sync (fun () ->
           lookup_user (User_id.value input.id)))))
    json
```

Decode issues carry structured paths:

```ocaml
Eta_schema.issue_to_json_pointer issue
```

`Field "users"; Index 0; Field "id"` renders as `users[0].id` and converts
to the JSON Pointer `/users/0/id`. A numeric object key remains a field, so it
renders as `users.0.id`.

Issues also carry structured kind and source fields:

```ocaml
type issue_kind =
  | Type_mismatch of { expected : string; got : string }
  | Missing_field of string
  | Custom of string
  | Refinement_failed of { name : string; reason : string }

type issue = {
  path : path_segment list;
  schema_name : string option;
  kind : issue_kind;
}
```

Named schemas such as records, enums, tagged unions, refinements, and
transforms stamp issues with `schema_name` when the lower-level issue has no
more specific source. Use `render_issue` for text and pattern-match on `kind`
for programmatic handling.

Concrete JSON libraries plug in through `JSON_ADAPTER` and `Make`:

```ocaml
module Codec = Eta_schema.Make (My_json_adapter)

let decode_user external_json =
  Codec.decode User.schema external_json

let encode_user user =
  Codec.encode User.schema user
```

The core package does not depend on Yojson or Ezjsonm. Adapters live at the
boundary where an application chooses its JSON library.

Limits:

- This package no longer exposes placeholder `Eta_schema.samples`.
- This package no longer exposes placeholder `Eta_schema.json_schema`. JSON Eta_schema
  generation should be a separate module with a chosen draft, real `$ref`
  handling, and validator tests.

## Development

Run the package tests:

```sh
nix develop -c dune runtest test/schema_eio --force
```

Run the full gate:

```sh
nix develop -c dune runtest --force
```

Without Nix, after `opam install . --deps-only --with-test`, use `dune runtest test/schema_eio --force`.
