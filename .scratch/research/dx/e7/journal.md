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

---

## Execution log

### V-DX-E7-001 — Predictions sealed

The prediction section above was committed as `b1c5a4de` before documentation,
implementation, tests, or example edits. It has not been edited since.

### V-DX-E7-002 — Docs-first contract

`README.md` and `docs/api-dx.md` documented supported closed polymorphic rows,
tag naming, five built-in payloads, `[@eta.render f]`, PPX-time rejection,
explicit `?error_pp` / `with_error_pp` wiring, totality, and telemetry stability
before the PPX implementation commit. Package metadata now lists typed-error
printers as a `ppx_eta` surface.

### V-DX-E7-003 — Generated code and rejection evidence

`eta_error` is the first `Deriving.str_type_decl` generator in `ppx_eta`. It
emits one constrained `pp_<type>` binding containing only `fun` + `function`
branches and qualified `Format` calls. Generated binders use ppxlib fresh
symbols so a named custom printer cannot be captured. Custom render attributes
accept printer identifiers (`f` / `Module.f`), not arbitrary expressions.

The committed corpus has the sealed **10 fixtures**:

| Evidence | Actual |
| --- | ---: |
| Nullary expansion | 1 |
| Built-in payload expansions | 5 |
| Mixed expansion | 1 |
| Built-in custom override expansion | 1 |
| Full compiler-error snapshots (unsupported payload, nominal variant) | 2 |
| **Total** | **10** |

Focused command:

```sh
nix develop -c dune runtest test/ppx_expansion test/ppx_eio test/type_errors --force
```

Result: PASS. The Eio golden test runs default and derived `Db 7` failures
through the same in-memory tracer and asserts `"<typed failure>"` before and
`"db:7"` after. It separately proves that a raising custom printer selected by
generated code returns `Cause.Die Failure("derived renderer exploded")`.

Manual compile probes also confirmed a parameterized row can derive through
`[@eta.render]`. A private row cannot be pattern-matched by the generated
binding, so the deriver rejects it directly with make-public/write-manual
guidance rather than leaking a generated-code type error.

### V-DX-E7-004 — Examples/docs renderer census

No concrete error declaration exists in `docs/`. Baseline commit `28743456` had
47 hand-written `pp_error` / `pp_never` / `pp_api_error` / formatter-style
`render_error` definitions across 47 example files. The final census is:

| Surface | Before | After | Coverage |
| --- | ---: | ---: | ---: |
| Hand-written example `Format` error printers | 47 | 0 | 100% removed |
| Derived error declarations | 0 | 54 across 49 files | 100% of local example error rows |
| `Effect.named` / `Effect.fn` sites with direct `~error_pp` | 0 | 23 / 23 | 100% |
| Concrete derivable error declarations in `docs/` | 0 | 0 | n/a |

Four nested payload sites derive the payload row and name that generated
printer via `[@eta.render pp_<payload>]`. The signal example explicitly lists
public tags and refutes its impossible observer-error payload during widening;
the deriver was not broadened to inherited rows. Remaining `render_*` functions
return domain strings for business mapping/output and are not `Format` error
printers.

Actual PPX census: extension-point/deriver forms **3 -> 4 (+1)**. Actual footgun
delta: **-1 / +0**; the effort barrier that preserved placeholders is removed,
and unsupported payloads still fail at PPX time.

### V-DX-E7-005 — Red-team

Artifacts: `.scratch/research/dx/e7/redteam/`.

1. Unsupported record payload cannot emit a placeholder; the PPX fails with the
   snapshotted built-ins/`[@eta.render]` guidance.
2. A raising custom printer selected by derived code becomes `Cause.Die`.
3. Consecutive commits `0def476c` and `28743456` rename `Db_down` to
   `Database_down`; real output changes from `db_down` to `database_down`.

All attacks passed. Generated compilation artifacts accidentally created during
the first manual tag probe were removed in the consecutive rename commit; only
source and recorded output remain.

### V-DX-E7-006 — Exact gates

All passed on the first attempt:

```sh
nix develop -c dune build @install          # PASS
nix develop -c dune runtest --force         # PASS
nix develop -c eta-oxcaml-test-shipped      # PASS
```

No generated code landed in a JS-track package, so the conditional mainline JS
gate was not required.

### Prediction score

| Sealed prediction | Actual | Score |
| --- | --- | ---: |
| 10 snapshot fixtures | 10 | 1/1 |
| Plain typed match, five built-ins, explicit override | Matched; hygienic binder names differ from illustrative names | 1/1 |
| 100% census and zero hand-written example printers | 54 derived declarations; zero targeted printers | 1/1 |
| PPX forms +1 | +1 | 1/1 |
| Footgun -1/+0 | -1/+0 | 1/1 |
| Review ratings / two likely misreadings | Packet prepared; external review pending | pending |

Observable prediction score: **5/5**. Review-rating predictions remain honestly
unscored until the randomized packet is reviewed.

### Deviations and remaining uncertainty

- Ppxlib places deriver output in its standard warning/Merlin `include struct`
  scaffold. The snapshotted generated binding inside is the required plain
  typed match; review excerpts omit only that standard scaffold.
- Hygienic fresh binder names replace illustrative `fmt` / `id` names. This is
  visible in snapshots and prevents capture without adding runtime machinery.
- Private polymorphic aliases are rejected after a real compile probe proved
  the generated external binding cannot pattern-match them.
- No human review rating is claimed. The packet is ready for that evidence.

### Verdict

**PROMOTE.** The one-pager gates are met: complete example coverage, zero
hand-written example `Format` error printers, exact positive/negative snapshots,
real `db:7` tracer evidence, explicit wiring, and green repository gates. The
payload long tail used the designed explicit escape hatch and did not force a
smarter or less reviewable PPX.
