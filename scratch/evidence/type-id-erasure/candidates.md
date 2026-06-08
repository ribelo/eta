# Candidates

## Site A — heterogeneous service map (`services : (int, Obj.t) Hashtbl.t`)
- A1. Keep `(int, Obj.t)` + `Obj.repr`/`Obj.obj`.
- A2. Replace with `Type.Id`-keyed dictionary (stdlib's own example). **Tested: 001.**

## Site B — typed-failure transport across fibers (`Raised_cause of int * Obj.t`)
- B1. Keep per-runtime `int` key + `Obj.repr`/`Obj.obj` (status quo, V-O9).
- B2. `Type.Id` witness WITHOUT changing the erased frame. **Tested: 002.**
- B3. `Type.Id` witness WITH an un-erased, `'err`-parameterized frame. **Tested: 003.**

## Site C — `Obj.magic runtime` (`runtime_erasure.ml`)
- C1. Keep: drops the phantom `'err` of `Runtime_core.t` so the frame is monomorphic.
- C2. Variance coercion `:>` instead of `Obj.magic`. (Infeasible: no `'err :> Obj.t` subtype relation.)
- C3. Drop the `'err` param from the internal runtime entirely. (Loses the public
      `run : 'err t -> ('a,'err) Effect.t` phantom constraint — out of scope.)
