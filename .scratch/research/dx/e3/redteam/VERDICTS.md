# E3 red-team verdicts

## RT-E3-1 — map-wrapped race vs `race_either`

**Workaround:**

```ocaml
Effect.race
  [
    timeout_eff |> Effect.map (fun t -> `Timeout t);
    work_eff |> Effect.map (fun v -> `Done v);
  ]
```

**Named:**

```ocaml
Effect.race_either timeout_eff work_eff
(* `Left timeout | `Right value *)
```

**Outcome:** Workaround only wins when the shared domain variant is already
required downstream. For a pure heterogeneous race, `race_either` removes the
double map without changing cancellation. Kill gate (Left/Right harder than
named variants at all call sites) not evidenced strongly enough to kill.

**Verdict:** PASS promote.
