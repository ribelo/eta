# DX-E5 Report — Negative compile tests and "Eta type errors, translated"

## Summary

Two deliverables:

1. **`test/type_errors/`** — the repo's first negative-compile snapshot
   corpus. 10 compile cases (3 supervisor rank-2 escapes, 7 PPX rejections)
   drift-gated by `dune runtest`; 3 runtime scenarios (cross-domain
   Channel/Queue) under the opt-in `@type-errors-runtime` alias. All
   snapshots are real captured output; the gate is fenced to the OxCaml
   5.2.0+ox compiler because message text is compiler-specific.
2. **`docs/type-errors.md`** — 8 entries, each quoting the snapshot
   verbatim (mechanically verified), with what-you-tried /
   why-Eta-forbids / two canonical fixes, ≤ 15 lines per entry.

## Corpus inventory with per-item verdicts

| Case | Verdict (sealed → actual) | Message |
|---|---|---|
| `supervisor_return.ml` | compile → compile | `This field value has type … which is less general than "'s. …"` |
| `supervisor_ref_leak.ml` | compile → compile | same class; message names neither `child` nor the ref |
| `supervisor_escape_type_s.ml` | compile → compile | same class with explicit `(type s)` |
| `ppx_sync_nonstring.ml` | compile → compile | `expected [%eta.sync "name" body]` |
| `sql_nonrecord.ml` | compile → compile | `eta.sql.table expects a record type declaration` |
| `sql_badfield.ml` | compile → compile | `eta.sql.table supports int, int64, string, bool, float, bytes, and option fields` |
| `sql_attr_payload.ml` | compile → compile | `attribute primary_key does not take a payload` |
| `sql_unknown_attr.ml` | compile → compile | `unsupported eta.sql.table column attribute: bogus` |
| `sql_nine_fields.ml` | compile → compile | `eta.sql.table all projection supports at most 8 fields` |
| `sql_bad_shape.ml` | compile → compile | `expected [%%eta.sql.table type users = …]` |
| resource escape (`with_resource`, `Pool.with_resource`) | not compile → **compiles** (no fence exists; page entry 8) | — |
| Channel across eta_par domains | runtime → runtime | `try_send` silently works; blocking pair **hangs with no message** (exit 124 under timeout) |
| `Queue` cross-domain (contrast) | — | completes cleanly — harness control |
| Pubsub/Pool across domains | runtime → **not probed** | same-family extrapolation from Channel's Sync_lock waiter design; marked as extrapolation |

Prediction misses recorded as data: the supervisor message never says
"would escape its scope" (it is always `less general than 's.`); two PPX
rejections (`requires at least one field`, `table type name is empty`) are
**unreachable from source** (empty records are syntax errors).

## Page entries

1. `less general than 's.` — supervisor child escape (all routes).
2. `expected [%eta.sync "name" body]`.
3. `eta.sql.table expects a record type declaration`.
4. `eta.sql.table supports int, int64, …` field types.
5. attribute discipline (`primary_key` payload / unknown attribute).
6. `eta.sql.table all projection supports at most 8 fields`.
7. The cross-domain hang (runtime, no message — quotes the real probe
   output, `exit=124`).
8. The escaped resource handle (no error exists; runtime-managed lifetime).

## Compiler-side-work by-product list

1. **Same-domain fence for Channel/Pubsub/Pool (top item).** Today a
   cross-domain blocking call hangs forever. Eta's own "break loudly" rule
   suggests a runtime fence: record the owning domain/runtime at creation,
   raise `Invalid_argument` on foreign-domain blocking ops. Cheap, turns a
   silent hang into a named error — and into a snapshot-able message.
2. **Supervisor escape message opacity.** `less general than 's.` never
   names the escape route. OCaml has no custom-type-error hook; Eta's lever
   was the page. No in-repo compiler fix short of re-encoding the rank-2
   brand (e.g., module-carried brands) — not recommended; the page covers it.
3. **Dead PPX rejections.** `requires at least one field` and
   `table type name is empty` are unreachable from source — delete
   candidates under the repo's no-dead-code rule (left in place; E5's fence
   is docs/tests).
4. **`Supervisor.Scope.start` first-contact error.** `start sup (Effect.pure 42)`
   fails with a raw `Effect.t vs Scope.t` mismatch (captured in the
   archaeology). A page entry or a `start` overload accepting plain effects
   would defuse it; deferred as out of category.

## Gates

```sh
nix develop -c dune build @install          # OK
nix develop -c dune runtest --force         # OK (snapshot gate included; drift negative-fixture verified)
nix develop -c eta-oxcaml-test-shipped      # OK
nix develop -c dune build @type-errors-runtime   # OK (opt-in)
```

## Census / footgun vs sealed predictions

| Metric | Sealed | Actual | Score |
|---|---|---|---|
| API vals | +0 | +0 | hit |
| Footguns | −3 / +0 | **−4 / +0** (entry 8 counts the no-error resource trap) | favorable miss |
| Compile-vs-runtime verdicts | 6 categories predicted | 5 hit, 1 partial (Pubsub/Pool extrapolated) | mostly hit |
| Message shapes | "would escape its scope" | `less general than 's.` | **miss** — page quotes the real text |
| Corpus size | 5–8 entries | 8 | hit |
| Review outcome | PASS-with-page | pending board | — |

## Red-team

Closure-leak and tuple-leak escapes (`r1`/`r2` in the archaeology) produce
the identical message class — the "never says escape" finding holds across
every route tried. The ref-leak's message is the most opaque observed: it
contains neither `child` nor the ref's name; page entry 1 says so
explicitly.

## Review outcome

Packet at `.scratch/research/dx/e5/review/` (rigged W5 ref-leak task,
verbatim error, page excerpt, two-phase protocol ending in the rank-2
teach-back). Board review pending with the orchestrator.

## Recommendation

**Promote unconditionally**, per the one-pager's gate. The corpus is
drift-gated, the page is verbatim-verified, and the by-product list above
is the follow-up work — led by the same-domain fence (#1), which converts
the worst finding (silent hang) into a named, testable error.
