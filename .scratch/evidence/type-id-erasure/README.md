# Decision: can `Stdlib.Type.Id` make Eta's `Obj` erasure more idiomatic?

Toolchain: `.opam-oxcaml/5.2.0+ox/bin/ocaml` (OCaml 5.2.0+ox). `Type.Id` is `@since 5.1`.

## Question

Two distinct `Obj` sites in `lib/eta`:

1. **Heterogeneous service map** — `services : (int, Obj.t) Hashtbl.t`
   (`runtime_core.ml`), packed via `Obj.repr`, read via `Obj.obj`.
2. **Typed-failure transport across fibers** — `exception Raised_cause of int * Obj.t`
   (`runtime_core.ml`), guarded by a fresh per-interpreter `int` key
   (`Typed_fail`), unpacked via `Obj.obj`.

Can `Type.Id` replace the raw `Obj.obj` cast with a type-witnessed, safe
recovery — given that Eta deliberately **erases** the error type in the frame
(`runtime : Obj.t Runtime_core.t`, `effect_core.ml`)?

## Proof questions

| # | Question | Evidence | Risk |
|---|---|---|---|
| 001 | Does `Type.Id` give a safe heterogeneous map with no `Obj.obj`? | positive fixture | low |
| 002 | Does `Type.Id` remove the unsafe cast from the *erased-frame* failure transport, or only relocate it? | diagnostic fixture | high |
| 003 | Could the failure transport be made safe by *un-erasing* the frame (carry `'err Type.Id.t`)? what does that cost? | diagnostic fixture | high |

Run: `bash run.sh`
