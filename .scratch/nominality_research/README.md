# Nominality Research

Focused lab for the accepted OCaml-first nominal/newtype module approach.

The question is capability parity, not Effect-TS API parity:

- a decoded string can become a distinct `User_id.t`;
- invalid raw strings cannot be used where `User_id.t` is required;
- `User_id.t` and `Email.t` cannot be mixed;
- schemas can still encode, decode, compare, and document the type.

Files:

- `b_b_abstract_newtype.ml` — OCaml-first abstract module/newtype shape.
- `b_c_witness_newtype.ml` — reusable functor/witness helper for reducing
  newtype boilerplate while keeping constructors hidden.
- `b_d_private_abbrev.ml` — OCaml private type abbreviation, e.g.
  `type t = private string`, for scalar contracts.
- `neg_abstract_newtype_plain_string.ml` — raw string cannot forge abstract
  `User_id.t`.
- `neg_abstract_newtype_mix.ml` — `Email.t` cannot be passed as `User_id.t`.
- `neg_witness_make_hidden.ml` — generated constructor remains hidden.
- `neg_private_abbrev_plain_string.ml` — raw string cannot forge private
  `User_id.t`.
- `neg_private_abbrev_mix.ml` — private `Email.t` cannot be passed as
  private `User_id.t`.

The rejected public wrapper candidate was removed after the decision. Its
compile evidence is preserved in `journal.md`, but maintained scratch files
now show only the accepted OCaml-first shapes.
