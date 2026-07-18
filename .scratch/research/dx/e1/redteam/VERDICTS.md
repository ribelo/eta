# E1 red-team verdicts

## RT-E1-1 — `sync_result` does not type-catch exceptions

**Attempt:** treat `sync_result` like an attempt combinator that maps a raised
exception into the typed error channel.

**Probe:** `Effect.sync_result (fun () -> failwith "boom")` under the common
runtime suite (`sync_result parity`).

**Outcome:** `Exit.Error (Cause.Die _)`. Typed failure path is only for
explicit `Error e`.

**Verdict:** PASS — name must not invite attempt-model; evidence shows Die.
