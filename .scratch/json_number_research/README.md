# JSON Number Representation Research

Backlog: Effet-a64.

Fixture set:

| Fixture | N0 float-only | N1 Int/Intlit/Float | N2 raw string | N3 int64 option + float |
|---|---|---|---|---|
| `0`, `1`, `-1` | round-trips through float | `Int` | exact | int64 fast path |
| `9007199254740993` | loses precision | `Intlit` exact | exact | int64 exact |
| `18446744073709551615` | loses precision | `Intlit` exact | exact | no int64 fast path |
| `1e100` | finite float, not int | `Float` or `Intlit` from adapters | exact | float fallback |
| `0.1 + 0.2` | prints binary float result | `Float` keeps current behavior | exact token only if parser keeps it | float fallback |
| `NaN`, `Infinity` | must reject at rendering | must reject as `Float`; invalid as `Intlit` | reject by JSON-number parser | reject float fallback |

Decision:

- Ship N1 in `packages/effet-schema`: `Json.Number of Json.number` with
  `Int | Intlit | Float`.
- Keep `Json.number : float -> t` for existing float call sites.
- Add `Json.intlit : string -> t` for exact large integer tokens.

Rationale:

- N0 is the defect: it silently collapses producer intent.
- N2 is exact but pushes parsing cost and validation to every decoder.
- N3 is more complex than N1 and still cannot represent uint64-max as an
  integer fast path on OCaml int64.
- N1 matches the OCaml ecosystem shape used by Yojson without taking a Yojson
  dependency in the schema package.
