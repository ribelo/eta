# DX-E32 Report — `fold ~ok:Fun.id` usage-data re-check

## Recommendation

**A — E23's verdict holds.** Keep `fold` as the only pure both-channel fold; do
not restore `recover`.

The frequency gate supports B: the textual cohort is exactly 26 occurrences in
10 OCaml files, with 24 genuine expressions/snippets after removing two scanner
sentinels, 11 consumer-shaped occurrences, and one additional README teaching
site. The decisive naming gate does not. A blinded review judged that `recover`
still materially suggests ordinary exception recovery at API-selection time.
The proposed contract corrects that expectation when read carefully but does
not prevent the name from creating it.

No library, test, example, README, or law-registry code changed. The branch adds
only the three required E32 research artifacts.

## Evidence ledger

- **V-DX-E32-1 — census:** `census.md` reproduces 26 textual occurrences / 10
  `*.ml` files, identifies two scanner sentinels, and classifies every match.
- **V-DX-E32-2 — variant hunt:** multiline searches plus identity-lambda checks
  found no `fun x -> x`, one-case `function x -> x`, or additional multiline
  recovery-only variants.
- **V-DX-E32-3 — consumption:** 6/10 files are examples, but they hold 7/26
  textual occurrences. The cohort has 11 consumer-shaped and 15 framework
  occurrences; two of the latter are scanner strings rather than calls.
- **V-DX-E32-4 — blind naming review:** an independent reviewer, given only the
  current `fold` semantics and proposed `recover` signature/contract, returned
  strict-gate **FAIL**, confidence 0.9. The signature does not expose unchecked
  exception behavior; “typed failure” and “defect” are not guaranteed newcomer
  vocabulary; the prose corrects rather than prevents the initial reading.
- **V-DX-E32-5 — A red-team:** at a teaching site,
  `fold ~ok:Fun.id ~error:f` is noisy and makes the unchanged success branch
  explicit. It does not create a distinct wrong semantic promise. `recover`
  would remove ceremony but would not prevent any observed `fold` misreading;
  instead it introduces the broader exception-recovery reading.
- **V-DX-E32-6 — gates:** all required Nix/OxCaml gates passed on the research-
  artifact-only tree.

## Census result

| Measure | Result |
|---|---:|
| Textual `*.ml` cohort | 26 occurrences / 10 files |
| Genuine executable expressions or pedagogical snippets | 24 |
| Scanner sentinels | 2 |
| Constant/error-independent genuine occurrences | 15 |
| Functions of the error | 9 |
| Consumer-shaped textual occurrences | 11 |
| Framework textual occurrences | 15 |
| Example files / occurrences | 6 files / 7 occurrences |
| Additional current README teaching site | 1 |
| Identity-lambda or missed multiline variants | 0 |

The orchestrator's textual measurement is exactly reproducible, but “26 sites”
is two too high semantically because the same literal appears in positive and
negative API-DX scanner assertions. Correcting to 24 does not undercut the
pre-registered approximate-20 bar. Consumer-shaped use is clearly present, so
frequency alone promotes B to the decisive review gate.

See `census.md` for the per-occurrence table and commands.

## Hypothesis ledger

| Candidate | Strongest evidence | Strongest counterevidence | Status |
|---|---|---|---|
| A — keep `fold` only | Avoids an exception-flavored selection name; explicit both-channel shape matches `Result.fold`; blind review fails B's decisive gate | 24 genuine repeated forms, including teaching code, retain visible `~ok:Fun.id` ceremony | **Accepted** |
| B — restore `recover` as documented `fold` shorthand | Frequency bar passes; implementation and semantic parity are mechanically straightforward; progressive disclosure can keep behavior conceptualized as `fold` | Blinded strict review finds ordinary-exception misreading materially plausible and says the prose repairs it only after reading | **Rejected by preregistered gate** |
| C — different name or shape | None investigated; the objective excludes silent selection | No evidence requires leaving A/B | **Out of scope, not rejected** |

## The 10 → 11 val tension

B's best argument is real: a shorthand can add a val without adding runtime
semantics. Exact equivalence, one-line implementation, tests, and bidirectional
cross-references could teach `recover` *as* the recovery-only projection of
`fold`. This follows E20's progressive-disclosure precedent: retain a general
operation and friendly special cases when the latter make common teaching code
substantially clearer.

That argument is insufficient here for two reasons:

1. Flat implementation semantics do not guarantee a flat user concept count.
   An eleventh name is another API-selection choice, and `recover` carries a
   broader pre-existing mental model than the typed channel it denotes.
2. Progressive disclosure works when the friendly name narrows the general
   operation without creating a competing semantic expectation. Here the name
   can be selected precisely because a newcomer wants to catch `failwith`; only
   the paragraph then reverses that expectation.

Therefore “10 → 11 vals, concepts flat” would be an accounting claim, not a
demonstrated DX result. The six example files increase the cost of the current
noise, but they also increase the cost of teaching a second, misleadingly broad
name. `examples/fold_recovery.ml` is especially discriminating: it deliberately
shows that a defect is not caught. Keeping `fold` makes the both-channel typed
boundary visible at the site where that lesson is taught.

## Red-team result for A

Adversarial question: does `fold ~ok:Fun.id` invite a wrong reading that
`recover` would have prevented?

The plausible complaints are syntactic, not semantic:

- a reader must recognize `Fun.id` as “success unchanged”;
- the success branch occupies attention at a recovery-only site;
- the form is longer than the intended shorthand.

None implies that defects are handled, that the error callback is effectful, or
that success is changed. The current `fold` contract explicitly says pure,
mirrors `Result.fold`, and states that defects/interruption/finalizer diagnostics
are not folded. `recover` removes all three syntactic costs, but it does not
prevent a wrong `fold` reading found by this pass. Its own name instead supports
the demonstrated exception-catching misreading.

## Parity and mechanical extras

Not applicable because A holds and the scope permits code changes only for B.
No `recover` implementation, migration, parity tests, or law row were added.
Existing E23 tests already exercise `fold` success/typed recovery, callback
defects, defect pass-through, interruption pass-through, and coherence with
`map` plus `bind_error`; all passed in the full gate.

Code-delta scope: **zero production/test/example/API changes**. Research delta:
`journal.md`, `census.md`, and `report.md` only.

## Required gates

| Command | Result |
|---|---|
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |

## Prediction scoring

| Sealed prediction | Actual | Score |
|---|---|---|
| 26 occurrences / 10 files | 26 / 10 textual cohort | hit |
| 0–2 identity/multiline variants | 0 | hit |
| Constant defaults roughly 8–12; error-derived 14–18 | 15 error-independent / 9 error-derived genuine occurrences | miss |
| Consumer-shaped clear majority | 11/26 textual (plus README), not a majority | miss |
| Frequency supports B | 24 genuine, 11 consumer-shaped; threshold passes | hit |
| Strict naming review reopens exception reading | Blinded review: fail, confidence 0.9 | hit |
| Final decision A | A accepted | hit |

Score: **5 / 7**. The high-level decision prediction survived, while the sealed
shape assumptions overstated consumer dominance and error-dependent callbacks.

## Protocol note

Predictions were committed first as `docs(dx-e32): seal predictions` and were
not edited afterward. During the subsequent census, one broad `git grep -l`
diagnostic unintentionally traversed the scope-fenced
`.scratch/research/dx-journal.md`; its output exposed only the filename (and an
aggregate repository count), not matching content. The command's result was
discarded, the sealed prediction commit predates it, and every reported census
number comes from the scoped `*.ml` searches recorded in `census.md`. No fenced
file was modified. This is a procedural deviation, recorded rather than hidden;
it does not contaminate the decision evidence.

## Final verdict

**V-DX-E32-A — keep `fold` as the only pure both-channel fold.**

- Status: ACCEPT.
- Decision: 24 genuine uses establish noise but do not override the decisive
  exception-misreading failure.
- Counterevidence: frequency and progressive disclosure give B a strong case.
- Remaining uncertainty: the orchestrator's independent review could judge the
  explicit typed-channel prose sufficient at selection time.
- Would change if: blinded/newcomer review consistently selects and explains
  `recover` as typed-failure-only before correction, including the `failwith`
  case.
- Confidence: high on the preregistered gate application; medium on external
  reviewer agreement.

**E32 READY FOR REVIEW**
