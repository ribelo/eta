# DX-E24b red-team verdicts

Run all probes from the repository root:

```sh
.scratch/research/dx/e24b/redteam/run-all.sh
```

## R1 — Strongest minimal top-level B loses structural events

**PASS (attack succeeds against B).** `policy_sequence.ml` gives B one generic
pre-step and one generic post-step observation around a top-level driver call.
For an `and_then` handoff whose left and right policies both finish immediately,
the existing policy emits four branch-local hooks in one public step:

```text
left input; left terminal output; right input; right terminal output
```

The top-level B wrapper sees only top-level input and `Second_phase 0`. It cannot
recover the hidden left terminal output or right pre-step. A structural observer
can represent them only by restoring policy-owned placement.

What this does not prove: top-level-only observer callbacks are impossible. They
are straightforward but are not semantic parity for current taps.

## R2 — A does not publish state after interpreter failure

**PASS (A survives).** The same probe raises from direct `step_with_hooks`, then
reuses the caller-owned original driver. The complete hook trace repeats and the
terminal metadata still reports attempt one. The promoted qcheck property repeats
this at all six possible hook-failure positions for 50 generated inputs.

## R3 — Tested C variants fail or add surface

**PASS (tested C variant is refused).** `c_hide_hook_negative.ml` packages a
three-parameter driver behind a two-parameter existential, then tries to accept a
driver-supplied interpreter. OCaml rejects the escaping existential hook type.

`c_pack_interpreter_positive.ml` is the fair positive control: it compiles and
runs when the matching interpreter is stored inside the package. That changes
ownership—interpretation is bundled with policy/driver—and therefore does not
deliver the proposed split.

What this does not prove: every possible seam refinement is impossible or
dominated. A materially different compiling C remains possible but unproven.

## R4 — `no_hook` is usable and discriminating

**PASS.** `no_hook_positive.ml` directly steps an ordinary `recurs` schedule with
no annotation. `no_hook_negative.ml` adds a `unit` hook and is rejected because
`unit` is incompatible with the uninhabited `Schedule.no_hook`.

## R5 — Surface census

**PASS.** `signature-census.sh` asserts:

- 8 hook-accepting external operations: Effect 3, Resource 1, Stream 4;
- 2 explicit no-hook HTTP signatures;
- 3 implementation interpreters serving 3 + 1 + 4 operations;
- 12 pre-E24b tap constructor calls in 4 test files;
- 25 post-follow-up calls after the composition and suspension/wrapper tables
  plus output-cancellation integration.

B's strongest shared-record spelling needs one pre/post observer type plus a new
label/contract on all 8 operations. Separate callbacks require 16 labels. The
count is evidence of public maintenance cost, not the reason B loses; R1's
semantic failure is decisive.

## R6 — D removes real surface and has a bounded recipe

**PASS.** `d-surface.sh` asserts the deletion consequences: 12 pre-E24b test
constructions, 2 tap vals, 1 public Hook constructor, 2 suspended stepping entry
points, 8 ternary effectful signatures, 2 no-hook HTTP annotations, 6 public tap
promises, and 3 production interpreters.

`d_recipe.ml` proves that ordinary custom-loop instrumentation logs every retry
attempt without taps. Its negative control sees only the final outer
`Second_phase` result of an `and_then` handoff; deletion cannot recover the two
branch-local terminal events and intentionally gives them up.

What this does not prove: external demand is zero. It proves there is no
in-repository producer and that the common top-level recipe is viable. A shipped
producer, concrete external structural use, or schedule-local observability
integration would reverse D before implementation.
