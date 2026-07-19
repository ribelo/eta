# DX-E7 Journal — Error-renderer deriver in `ppx_eta`

Branch: `research/dx-e7-error-pp-deriver`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e7`
Phase: C (syntax & PPX)

## Predictions (sealed)

Sealed before documentation, implementation, test, or example edits. Wrong
predictions stay as evidence; this section will not be edited after its commit.

### Expected expansion shapes and snapshots

The generated item will be one ordinary, explicitly typed binding per declared
type:

```ocaml
let pp_err : Format.formatter -> err -> unit = fun fmt -> function
  | `Not_found id -> Format.fprintf fmt "not_found:%s" id
  | `Db code -> Format.fprintf fmt "db:%d" code
  | `Unavailable -> Format.pp_print_string fmt "unavailable"
```

Predicted built-in payload calls are `%s`, `%d`, `%Ld`, `%g`, and `%b` for
`string`, `int`, `int64`, `float`, and `bool`. A custom `[@eta.render f]`
payload remains the same plain branch and prints `"tag:"` followed by `f fmt
payload`; there will be no generated registry, runtime lookup, or placeholder.
The value name is `pp_<type-name>` and tag text is the constructor spelling
lowercased with existing underscores preserved (`Not_found` -> `not_found`).

Predicted snapshot corpus: **10 fixtures total**.

| Shape | Positive fixtures |
| --- | ---: |
| Nullary constructor | 1 |
| One fixture for each built-in payload (`string`, `int`, `int64`, `float`, `bool`) | 5 |
| Mixed nullary/built-in declaration | 1 |
| `[@eta.render f]` override | 1 |
| **Positive subtotal** | **8** |

Two negative fixtures bring the total to ten: unsupported payload and nominal
variant. Their snapshots will include complete compiler error text. I predict
both failures identify the rejected declaration/constructor location, say what
shape is unsupported, and tell the user either to choose a built-in payload or
add `[@eta.render f]` (unsupported payload), or use a polymorphic variant/manual
printer (nominal variant).

### Expected coverage census

Read-only pre-census found no concrete derivable error declaration in `docs/`.
In `examples/`, the relevant surface is every explicit or readily made-explicit
polymorphic error row whose top-level error output is currently formatted by a
hand-written `Format` printer. I predict **100% renderer coverage** for that
surface and **zero hand-written example error printers remaining** after making
inline/no-error rows explicit where necessary. Nested polymorphic-variant
payloads will derive their own payload printer and use `[@eta.render
pp_<payload-type>]`; the composed signal row will be made explicit locally
rather than broadening the deriver to row inheritance.

Predicted observability wiring: every `Effect.named` / `Effect.fn` site in the
census whose typed failure row has a derived printer will receive explicit
`~error_pp:pp_error` (or an enclosing `Effect.with_error_pp pp_error` where one
subtree owns several spans). There will be no automatic PPX-to-runtime wiring.

Predicted census deltas:

| Cluster | Before | After | Delta |
| --- | ---: | ---: | ---: |
| PPX forms (`eta.fn`, `eta.sync`, `eta.sql.table`, derivers) | 3 | 4 | **+1** |
| Error-renderer derivation concepts | 0 | 1 | **+1** |

**Footgun delta prediction: -1 / +0.** Removed footgun: named spans silently
retain the meaningless `"<typed failure>"` default because writing a complete
formatter is enough work to skip. No new footgun is predicted because unknown
payloads fail during PPX expansion and the generated printer remains an ordinary
explicit value.

### Expected review ratings

Using a five-point review scale (1 = reject, 5 = approve):

| Material | Before | After |
| --- | ---: | ---: |
| Telemetry meaning for the same typed failure | 1/5 (`<typed failure>`) | 5/5 (`db:7`) |
| Expansion readability / PR approval | n/a | 4/5 |
| Wiring transparency | 3/5 (socket exists but is easy to omit) | 5/5 (derived plain value passed explicitly) |

I predict reviewers approve the expansion verbatim, with the likely reservation
that generated telemetry strings are an API whose stability must be documented.

### Two likeliest reviewer misreadings

1. **“`[@@deriving eta_error]` automatically installs telemetry policy.”** It
   does not. The generated `pp_<type>` is an ordinary function; a caller must
   pass it through `?error_pp` on `Effect.named` / `Effect.fn` or scope it with
   `Effect.with_error_pp`.
2. **“Unknown payloads fall back to a generic placeholder.”** They do not. An
   unknown payload is a PPX-time error unless its constructor names an explicit
   payload printer with `[@eta.render f]`; a raising selected printer follows
   the existing E25 contract and becomes a defect.

### Promote / hold / kill prior

Predict **promote** if all ten snapshots, the real-tracer `db:7` golden test,
100% eligible census coverage, zero hand-written example error printers, the
red-team probes, and all three Nix gates pass. Hold for incomplete evidence or
unclear rejection text. Kill if supporting the actual example payloads requires
generation beyond a reviewable plain match rather than the explicit escape
hatch.

### Journal-only backlog notes (do not change in E7)

The two pre-existing dead rejection paths in `lib/ppx/ppx_eta.ml` remain out of
scope: the empty result of `String.split_on_char` in `longident_of_path`, and the
zero-field record branch in `projection_constructor`. E7 will not delete or
rewrite either path.
