# DX-E24c observation recipes

Observe the operation that is retried, repeated, loaded, or emitted—not the
schedule policy.

| Operation | Recipe | Observation boundary |
| --- | --- | --- |
| `Effect.retry` / `retry_or_else` / `repeat` | Instrument the source effect before passing it to the operation. | Every source attempt, including the initial attempt. |
| `Resource.auto` | Instrument `load`; use an application counter to distinguish seed and refresh loads. | Loads, not terminal schedule exhaustion. |
| `Stream.retry` | Put `Stream.tap_error` on the source before `retry`, or instrument the source. | Each source failure; an outside tap sees only the final failure. |
| `Stream.repeat` | Instrument the source or apply `Stream.tap` to the repeated stream. | Source evaluations or emitted values, not empty repetitions or schedule exhaustion. |
| `Stream.schedule` / `from_schedule` | Use `Stream.tap` on the resulting stream. | Emitted values only. |
| Custom driver | Observe immediately around direct `Schedule.step`. | Top-level input and decision only. |

```ocaml
let attempts = ref 0 in
let observed = ref [] in
let request =
  Effect.sync (fun () ->
      incr attempts;
      observed := !attempts :: !observed)
  |> Effect.bind (fun () -> request_once)
in
Effect.retry ~schedule:(Schedule.recurs 2) ~while_:retryable request
```

## Boundary: no parity

These are not replacements for schedule-local taps. The deleted channel could
place effects around structural schedule evaluation, including terminal
non-emitted values, policy-generated outputs, state-publication vetoes, and
branch/phase-local events within one composed step. Ordinary operation
instrumentation cannot recreate those boundaries. E24c accepts that loss because
no shipped producer or external adoption demonstrated demand for it.

Executable evidence: the integration test
`retry attempts can be observed without schedule taps` and
`redteam/e24c/run-recipe.sh`.
