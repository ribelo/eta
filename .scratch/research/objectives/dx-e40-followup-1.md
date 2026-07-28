# Follow-up 1: DX-E40 — HOLD; four precise fixes before promotion

Independent review found the central admission guarantee is **false on the
Eio backend** — and reproduced it: `par_run_forks` registers children via
sequential `List.iter fiber_fork`, Eio runs each new child immediately, so
a synchronously-failing first child prevents later children from being
forked at all (`all [mark 0 |> bind (fun () -> fail "boom"); mark 1;
mark 2]` → `started=[0]`; children 1, 2 never admitted). The barrier tests
pass only because their children cooperatively yield. Four fixes, in
order:

## Fix 1 — admission gate for `all` and `all_settled`

Make "every child is admitted" true. Register every child fiber with its
first action waiting on a start gate; release the gate only after the
registration loop completes. Both operations share the immediate-
admission contract, so both get the mechanism (one implementation, shared
honestly — do not contort). The gate must interact correctly with
fail-fast: a child failing during the gated phase cancels the group, and
children not yet started must not run; children already started are
cancelled per the existing `par_run_forks` semantics. If you find the
gate cannot be stated within the mli's doc budget, STOP and report — the
contract, not the implementation, then changes.

## Fix 2 — admission regression under synchronous failure

A backend-level regression test: an `all` (and `all_settled`) group whose
first child fails synchronously must still REGISTER every child (count
fork registrations / admissions), with the group exit failing fast. Pin
both directions: every child registered; non-started children do not run
their bodies. Also pin the non-cooperative case honestly if it is
expressible in the test runtime (a child that never yields — document
what the guarantee means there: full admission does not make
non-cooperative bodies schedulable).

## Fix 3 — CHANGELOG breaking entry

Omitted `Effect.all effects` calls keep compiling while silently changing
from cap-8 to unbounded. Add the entry to `CHANGELOG.md` (extend the
idiom-pass entry or a new Unreleased section, matching the file's
existing structure):

```text
all ~max_concurrent:n effects  →  all_bounded ~max_concurrent:n effects
all effects                    →  now forks one fiber per input (was: at
                                  most 8 admitted at once)
```

## Fix 4 — footgun registration and docs warning

The split removes one hidden trap (silent cap-8 stall) and introduces
another (unbounded fan-out): `all` over a 10k-element collection forks
~10k fibers. Footgun delta is **−1/+1**, not −1/+0 — correct it in your
journal and the dossier. Docs (`docs/api-dx.md` + the `all` mli) must
say: `all` forks one fiber per input; reserve it for finite groups
requiring full admission; use `all_bounded` for large or data-derived
independent prebuilt effects; use `map_par` when lazily mapping.

## Journal

New `Amendment predictions (sealed)` section committed BEFORE the fix
code: predicted gate semantics for the fail-fast-during-gated-phase case,
predicted regression-test outcomes, predicted law-row text changes. Then
update the law rows that overclaimed (the "admits every generated child"
properties must either pin the gate or be reworded to the cooperative
boundary — the gate makes the strong form true, so pin the gate).

## Gates

Full set after fixes (native trio + mainline JS targets with
`--build-dir=_build-mainline`), plus focused runs of the new admission
regression tests and the law properties. Status files under
`.scratch/research/dx/e40/dossier/`.

## Report

Append: the four fixes, gate results, amendment prediction scores, and
your final recommendation.

## Done means

Same signals: `E40 READY FOR REVIEW` / `E40 BLOCKED: <reason>` /
`E40 STOP: <§4.6>`. Same scope fence (and per the new rule: exclude
fenced paths by glob in repo-wide searches). This file stays uncommitted.
