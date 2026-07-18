# E2 red-team verdicts

## RT-E2-1 — swallowed-error cleanup is explicit

**Old bug shape (unwriteable now):**

```ocaml
Effect.pure (cleanup ()) |> Effect.ignore
(* looked like Stdlib.ignore; also suppressed typed failures *)
```

**New honest shapes:**

```ocaml
cleanup_effect |> Effect.discard
(* typed failures still fail *)

cleanup_effect |> Effect.ignore_errors
(* explicit best-effort: typed failures suppressed; defects visible *)
```

**Verdict:** PASS — the silent swallow requires naming `ignore_errors`.
