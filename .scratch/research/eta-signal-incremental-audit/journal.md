# Journal — eta_signal vs incremental audit

## 2026-08-04

- Scope settled via batch-grill-me (rounds 1–2): lib/signal + lib/signal_map;
  API + semantics + internals; both directions; local pinned references;
  tests/benches/LAWS.md graded; `.scratch/research` bundle; GPT Pro handoff
  with EARS/invariant corrections, minimal code.
- Cloned `incr_map` @ v0.18~preview.130.106+341 to
  `~/projects/github/incr_map`, symlinked `.reference/incr_map` per the
  checkout convention.
- Installed current worktree into the OxCaml switch for probe fidelity
  (`dune build @install && dune install eta eta_stream eta_observability
  eta_signal eta_signal_map`; `eta-opam-install` fails on an unrelated
  `eta_ai_kimi_coding → eta_ai_openai_compat` opam conflict — pre-existing,
  not touched).
- Full read: eta_signal public interface, all support modules, the 3.7k-line
  kernel, eta_signal_map; incremental's `incremental_intf.ml`, `node.ml`,
  `state.ml`, `scope.ml`, `recompute_heap.ml`, `cutoff.ml`; `incr_map`'s
  `incr_map{,_intf}.ml`; tests, benches, LAWS.md.
- Probes (built against installed `eta_signal 5694938`, `EIO_BACKEND=posix`):
  - probe_depth: chains 1k → 1.6M nodes all stabilize OK (results-depth.txt).
    Inverts the expected stack-depth concern; contrast incremental's default
    `max_height_allowed = 128`.
  - probe_scale: recompute_count is change-proportional (half-graph on a
    single-var set at every size); per-stabilize wall time is O(graph) even
    for idle/no-op stabilizes, 260 ms at 100k nodes, superlinear
    (results-scale.txt). Primary evidence for F1.
- Wrote REVIEW.md (matrix, 17 semantic rows, internals, eta-only grading,
  tests/laws grading, 14 findings F1–F14, no P0).
- Citation pass over REVIEW.md line references; corrected one intf range.
