# DX-E24b red-team verdicts

Run all probes from the repository root:

```sh
.scratch/research/dx/e24b/redteam/run-all.sh
```

R1–R5 below are retained historical findings from the ownership experiment.
Their hook fixtures no longer run after E24c because the surface they exercised
was deliberately deleted. `run-all.sh` now runs only the surviving post-deletion
surface and ordinary-recipe checks.

## R1 — Strongest minimal top-level B loses structural events (historical)

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

## R2 — A does not publish state after interpreter failure (historical)

**PASS (A survives).** The same probe raises from direct `step_with_hooks`, then
reuses the caller-owned original driver. The complete hook trace repeats and the
terminal metadata still reports attempt one. The promoted qcheck property repeats
this at all six possible hook-failure positions for 50 generated inputs.

## R3 — Tested C variants fail or add surface (historical)

**PASS (tested C variant is refused).** `c_hide_hook_negative.ml` packages a
three-parameter driver behind a two-parameter existential, then tries to accept a
driver-supplied interpreter. OCaml rejects the escaping existential hook type.

The compile fixtures and runner were removed when E24c deleted the hook type;
keeping them in the executable packet would test an API that no longer exists.
The E24b report preserves their result: existential hiding failed, while storing
the matching interpreter inside the package compiled but changed ownership.

What this does not prove: every possible seam refinement is impossible or
dominated. A materially different compiling C remains possible but unproven.

## R4 — `no_hook` is usable and discriminating (historical)

**SUPERSEDED BY DELETION.** The fixtures and runner were removed. Every schedule
is now directly step-able, so retaining a `no_hook` discrimination probe would
misdescribe the product.

## R5 — Surface census (historical)

**PASS (historical census preserved in the E24b report).** Before deletion this
counted 8 hook-accepting operations, 2 `no_hook` HTTP signatures, 3 production
interpreters, and 25 post-follow-up tap constructions. After E24c,
`signature-census.sh` instead guards the landed binary signatures and absence of
legacy hook references; it no longer pretends the historical fixtures compile.

## R6 — D removes real surface and has a bounded recipe (current)

**PASS when run against completed E24c.** `d-surface.sh` now asserts the landed
state: zero tap vals, Hook constructors, suspended stepping entry points, or
legacy hook references in `lib/` and `test/`; the 8 effectful and 2 HTTP
signatures use binary schedules.

`d_recipe.ml` proves that ordinary custom-loop instrumentation logs every retry
attempt without taps. Its negative control sees only the final outer
`Second_phase` result of an `and_then` handoff; deletion cannot recover the two
branch-local terminal events and intentionally gives them up.

What this does not prove: external demand is zero. It proves there is no
in-repository producer and that the common top-level recipe is viable. A shipped
producer, concrete external structural use, or schedule-local observability
integration would reverse D before implementation.
