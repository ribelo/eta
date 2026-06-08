# P-B — Value.t Widening Through Function-Call Boundary

**Status**: completed (real benchmark, captured log)
**Build log**: `scratch/eta_research/duckdb_connector/pb_value_union/bench.log`

## Test Design

Fixed the previous flawed benchmark:
- **Before**: Constructor allocation in a single hot loop (compiler can inline/optimize heavily)
- **After**: `[@no_inline]` functions in separate modules returning Value.t, called 10M times, pattern match on result

This tests the real hypothesis: does widening Value.t from 7 to 15 constructors cost anything when values cross a function boundary (like a typed builder's extract path)?

## Benchmark Code

```ocaml
(* Separate module, no_inline *)
let get_value idx =
  match idx mod 7 with
  | 0 -> Int idx
  | 1 -> Int64 (Int64.of_int idx)
  | ...
[@@no_inline]

let extract_int = function
  | Int i -> i
  | Int64 i -> Int64.to_int i
  | ...
[@@no_inline]
```

## Results

| Metric | V7 (7 cases) | V15 (15 cases) | Delta |
|--------|--------------|----------------|-------|
| Time | 0.032 s | 0.033 s | +0.7% |
| minor_words | 24,117,193 | 24,117,193 | 0.0% |
| major_words | 40 | 40 | 0.0% |
| per_iter | 2.41 words | 2.41 words | 0.0% |

## Analysis

**Zero measurable difference** across function-call boundary. The OCaml compiler generates the same code for the shared constructors regardless of how many other constructors exist in the type.

This confirms: widening Value.t does not tax SQLite call-sites through the bind/extract path.

## Verdict

**CONFIRMED** — No overhead detected through function-call boundary.

## Artifacts

- Benchmark log: `scratch/eta_research/duckdb_connector/pb_value_union/bench.log`
- Source: `scratch/eta_research/duckdb_connector/pb_value_union/pb_bench.ml`
- Command: `nix develop .#oxcaml --command dune exec scratch/eta_research/duckdb_connector/pb_value_union/pb_bench.exe`
