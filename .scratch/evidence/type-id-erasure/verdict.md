# Verdict — `Type.Id` vs Eta's `Obj` erasure

Toolchain: OCaml 5.2.0+ox via `nix develop --offline .#oxcaml`.
Evidence: `bash run.sh` (001 PASS, 002 diagnostic, 003 PASS). All three compile and run.

Prior art: journal **V-O9** ("Obj.t boundary audit") already inventoried every
`Obj` site and recommended keeping the failure transport. This entry re-tests it
specifically against `Stdlib.Type.Id` on the current `lib/eta` layout and adds the
decisive erased-frame argument V-O9 did not make explicit.

## Facts established by code reading
- `Runtime_core.t`'s `'err` is a **pure phantom** (appears in no field). It exists
  only on the public `Runtime.t` to constrain `run`. `Obj.magic` in
  `runtime_erasure.ml` drops that phantom; sound and contained.
- The frame is **deliberately monomorphic**: `runtime : Obj.t Runtime_core.t`,
  `fail_key : int`. A single static frame flows through `eval` for every error type.
- `catch`/`map_error`/`tap_error` carry typed failures as plain `Exit.Error`
  **values** — no exception, no `Obj`, within one interpreter.
- `Raised_cause of int * Obj.t` + `Obj` is used **only at fiber crossings**
  (fork/par/race/timeout), guarded by one per-runtime `default_fail_key`.

## Verdicts

### V1 — Site A (service map): ACCEPT `Type.Id`
`Type.Id`-keyed dictionary replaces `(int, Obj.t)` with zero `Obj.obj`, type-safe,
miss→None (001). It is the stdlib's own documented use case. Local change confined
to `Runtime_core` service storage + `Runtime_contract.Service`. **Idiomatic win, no
architectural problem.**
Confidence: High. Would change if: a measured hot-path cost from `provably_equal`
on service lookup proved material (service reads are rare, so unlikely).

### V2 — Site B (failure transport): REJECT `Type.Id` (keep B1)
`Type.Id` certifies a cast only when the SAME `'err`-typed witness reaches both the
pack site (fork) and the unpack site (join). Eta's frame is erased, so it can hold
only a fixed-type witness; fresh-per-site ids never match → recovery fails (002).
The only way to make it safe is B3: un-erase the frame into `'err frame` (003 PASS,
zero `Obj`) — but that turns `'err` into a **viral type parameter** threaded through
`frame` at ~300 sites across 12 files, re-introducing exactly the phantom that
`Obj.magic` deliberately drops today. With the erased frame, `Type.Id` only
**relocates** `Obj` onto the witness; it does not remove it.
The status-quo `int` key + `Obj` is well-contained: one private exception, one key,
documented guard, V-O9 regression tests.
Confidence: High (compile-tested both directions).
Would change if: a future refactor un-erases the frame for unrelated reasons —
then B3 becomes a free safety upgrade and should be taken.

### V3 — Site C (`Obj.magic runtime`): KEEP (PARTIAL)
Drops a phantom `'err`; `:>` is infeasible (no subtype relation, C2). Could be
removed by deleting the `'err` param from the internal runtime (C3) but that erodes
the public `run` phantom constraint — out of scope for an "idiomatic cleanup".
Lowest-value target. Lower risk than I first claimed: it is `%identity`-equivalent.

## Answer to the two questions
1. Can we use `Stdlib.Type.Id`? Yes — present in 5.2.0+ox with `provably_equal`.
2. Make it more idiomatic without a problem? **Only at Site A (services).** Site B
   hits a real architectural wall: the erased frame is load-bearing and `Type.Id`
   needs the type witness threaded, which Eta intentionally erases. Site C is a
   contained phantom drop best left alone.
