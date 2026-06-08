# P0-T5 Bind/Map Once Probe

Status: final for Effet-OxCaml-ss6.

Question: should Phase 4 make Effect.t values once/linear so Bind and Map continuations can be once, or keep Effect.t reusable with portable callbacks?

## Artifacts

- many_ast_once_continuation.ml: reusable AST with a once Bind continuation.
- once_ast_reuse_negative.ml: AST interpreter consuming once nodes.
- once_program_second_run_compiles.ml: isolated check for a run argument annotated @ once.
- portable_continuation_reuse_positive.ml: reusable portable AST with portable Bind/Map callbacks.
- portable_continuation_capture_negative.ml: portable callback capture-safety negative.
- results/compile.out and per-fixture logs: command transcripts.

## Command

    nix develop .#oxcaml -c bash scratch/oxcaml_research/bind_once_probe/run.sh

Last result:

    summary: pass=5 fail=0

## Evidence

Candidate A fails: a reusable AST that stores a once Bind continuation becomes once at the program value. The compiler rejects reusing the program with: This value is once but is expected to be many.

Candidate B is not a clean fit. A real once AST interpreter hits constructor/value mode friction immediately: extracting Pure v from a once node yields a once value where the interpreter wants many. An isolated @ once run argument also does not by itself reject a second run of an ordinary AST value, so linear Effect.t would require a deeper representation change, not just a run signature annotation.

Candidate C passes: portable continuations preserve ordinary Effect.t reusability. The same program evaluates twice. Its negative fixture rejects a Bind continuation that captures int ref, so the capture-safety goal is still enforced.

## Decision diary

- V-P0T5-1 - Keep Effect.t reusable/many.
  Decision: Phase 4 should not make Effect.t globally once or linear.
  Rationale: current Effet examples, tests, and benchmarks treat effects as ordinary reusable values. The once-AST probes introduce mode friction without evidence of user benefit.

- V-P0T5-2 - Do not type Bind/Map continuations as once.
  Decision: Bind and Map continuations should be portable where domain execution needs portability, not once.
  Rationale: many_ast_once_continuation fails on reuse. once_ast_reuse_negative shows interpreting a once AST is not a local annotation tweak.

- V-P0T5-3 - Keep once for resource finalizers and other true one-shot protocols.
  Decision: acquire_release release remains the right once-mode target; Bind/Map are not.
  Rationale: release has a real at-most-once protocol. Bind/Map continuations are called once per interpretation, but the AST can be interpreted many times.

## Deferred

- Phase 4 should annotate portable Bind/Map continuations as portable and include positive/negative capture fixtures.
- Phase 4 should not claim runtime per-visit call count as a static once property unless a future linear AST design deliberately removes reuse.

