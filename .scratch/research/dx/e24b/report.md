# DX-E24b report — schedule-hook ownership

## Verdict

**A lands: retain policy-owned typed hooks permanently.** The third
`Schedule.t` parameter carries values placed by policy composition; drivers
interpret those values through the suspended plan. B's per-driver observers are
not semantic replacements because they cannot see branch- or phase-local events.
The current architecture is already seam-centered, so the tested C redesigns add
surface, fail the existential type boundary, or reverse ownership.

No runtime code changed. Production changes are limited to ownership prose in
`lib/eta/schedule.mli`, one discriminating qcheck law, E22 registrations, and the
permanent parking-lot decision.

## Inventory result

- 8 effectful external operations: Effect 3, Resource 1, Stream 4.
- 3 production interpreter helpers serving 3 + 1 + 4 operations.
- 2 explicit no-hook HTTP signatures using `next`.
- Full public driver protocol: `start`, `step_plan`, `step_with_hooks`, `step`,
  `next`, and `no_hook`.
- `Eta_js` re-exports the same Schedule protocol.
- 12 pre-E24b tap constructor calls in 4 test files; zero production producers.
  The assignment's “16 lines, 3 files” used a different/stale unit; the committed
  census script asserts the repository result.

## Semantics matrix

| Row | A | B | C |
| --- | --- | --- | --- |
| Pre-step | Structural, local, suspended before inner step | Top-level only | Requires retained plan |
| Post-step / `Done` | Every local output, including hidden terminal output | Outer output only | Requires retained plan |
| Failure / advancement | No next driver before interpreter success | All 8 APIs must honor the contract; a helper may centralize it | Existing continuation solves it |
| Composition order | Exact nested order | Fails `and_then` handoff probe | Existing A is seam-centered |
| Suspended interpretation | Public `Hook (value, resume)` | Replaced by per-driver protocols | Hidden hook cannot take external interpreter |
| No-hook ergonomics | Inferred positive; tapped direct use rejected | Binary type, but 8 observer labels/contracts | At most shortens explicit aliases |

## Evidence and E22 reckoning

`redteam/run-all.sh` is the one-command evidence gate. Its decisive result is 4
branch-local A hooks versus 2 top-level B observations in one `and_then` step.
The C negative fixture produces the expected escaping-existential error; the
positive control works only with a packaged interpreter. No-hook positive and
negative fixtures prove inference and rejection.

The promoted property
`Schedule policy hook order survives and_then and step_with_hooks publishes only after interpreter success`
runs 50 generated inputs across all six failure positions. E22 M95/M96 register
the new prose and direct interpreter behavior; R96 now includes Effect, Resource,
and Stream evidence. CD-E22-022 is removed as closed. Schedule direct qcheck rows
increase 6 → 8 and total registered schedule rows 9 → 11.

## Census and footgun deltas

| Metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `Schedule.t` parameters | 3 | 3 | 0 |
| Schedule tap vals | 2 | 2 | 0 |
| Hook-accepting external operations | 8 | 8 | 0 |
| Production interpreter helpers | 3 | 3 | 0 |
| Direct schedule qcheck claims | 6 | 8 | +2 |
| Registered schedule rows | 9 | 11 | +2 |

Public API footguns: **0 removed / 0 added**. Documentation footguns:
**−1 / +0** — the unexplained third parameter now states the ownership split.
The type's visible complexity remains because the evidence shows it is
load-bearing, not because migration would be expensive.

## Cross-tab and statuses

| Candidate | Positive | Disconfirming result | Status |
| --- | --- | --- | --- |
| A | One typed plan across all drivers and custom interpreters | No production tap producers | **ACCEPTED** |
| B | Binary schedule and locally named lifecycle callbacks | Cannot represent branch/phase-local composition without recreating A | **REJECTED** |
| C | Correct focus on the suspended seam | Current A already has it; tested hiding fails or bundles interpretation | **REJECTED (dominated)** |

Strongest unresolved risk: repository evidence proves capability and semantics,
not external user demand. Full hook parity is not separately tested through all
eight operations, though each routes through one of three covered helpers.

## Prediction scoring

| Prediction | Actual | Score |
| --- | --- | --- |
| A accepted | A accepted | Hit |
| B duplicates contracts or loses composition | Both demonstrated | Hit |
| C does not materially reduce signatures | Tested variants do not | Hit |
| E22 has a gap | CD-E22-022 closed | Hit |
| Broad consumers, test-only producers | 8 consumers, zero production producers | Hit |
| Provisional tap census | 12 calls / 4 files, not 16 lines / 3 files | Miss |

## Verification

Final evidence and gates:

```text
.scratch/research/dx/e24b/redteam/run-all.sh
PASS

nix develop -c dune runtest test/laws --force
PASS — 64 properties; each of 50 generated ownership inputs exercises all 6
interpreter-failure positions

nix develop -c dune runtest test/laws test/core_eio test/stream_eio --force
PASS — baseline law gate, 569 core tests, 72 stream tests

nix develop -c dune build @install
PASS

nix develop -c dune runtest --force
PASS (rerun after the deterministic all-position correction)

nix develop -c eta-oxcaml-test-shipped
PASS

nix develop .#mainline -c dune build --build-dir=_build-mainline @install
PASS (OCaml 5.4.1)

nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws --force
PASS — 64 properties (rerun after the deterministic correction)

nix develop -c dune build @doc
PASS after installing the missing official odoc tool with
`nix develop -c opam install -y odoc` (odoc 3.2.1); existing unrelated odoc
warnings remain in `capabilities.mli` and `random.mli`
```

## Independent review

Oracle review agreed that composition makes A decisive, then found four evidence
quality defects: randomly sampled rather than guaranteed failure positions, a
baseline census tied to moving `HEAD`, imprecise M95/M96 claim spans, and
overstated B implementation duplication. The final tree executes all six
failure positions for every input, pins the census to the prediction commit,
splits the registry claims exactly, updates both 101/64 census locations, and
states that B may share an implementation while all eight APIs must honor the
contract. Its final content verdict had no remaining finding. An independent
Finder audit confirmed all consumers, counts, re-exports, and test registrations.

## Follow-ups and agreement

No B/C follow-up proposal is registered because A lands. External adoption and
full per-operation parity remain explicit uncertainty, not backlog commitments.
The shipped code and journal agree: runtime behavior is unchanged; prose, laws,
registry, parking lot, review packet, and verdict all retain policy-owned hooks.
