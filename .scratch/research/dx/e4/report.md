# DX-E4 Report — Cause rendering: `pp_compact`, structured encoding, snapshot corpus

## Summary

Three pieces, independently promotable:

1. **`Cause.pp_compact`** — one-line cause rendering for span statuses and
   log fields: `fail(err)`, `die(Exn("msg"))`, `interrupt` / `interrupt#id`,
   `a + b` concurrent, `a ; b` sequential, `finalizer(f)`,
   `p | suppressed: f`. Total and newline-free by construction (embedded
   payloads sanitized); defect metadata omitted by contract.
2. **Snapshot corpus** — the five one-pager cases + four extra, each locked
   both ways (`pretty` + `pp_compact`) as exact strings in
   `test/core_common/cause_render_common_suites.ml`, plus an exhaustive
   ~380-cause newline-freedom property. Rendering drift now fails CI.
3. **`Eta_otel.Cause_json`** — structured JSON encoding over
   `Cause.Portable.t` (private `lib/otel/cause_json.ml`, re-exported with a
   public mli signature). Core stays JSON-free. Sinks stop re-implementing
   tree walks.

Side effect: `Cause.interrupt_id_to_int` — the encoder needs interrupt
identity; `interrupt_id` had no accessor. See census.

## Gates

```sh
nix develop -c dune build @install          # OK
nix develop -c dune runtest --force         # OK (515 core incl. 12 new; 30 otel incl. 5 new)
nix develop -c eta-oxcaml-test-shipped      # OK
nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo   # OK
```

jsoo build shows two pre-existing integer-overflow warnings in unrelated JS
stubs; the `cause.mli` change compiles clean on the mainline track.

## Corpus inventory

Expect-locked in `test/core_common/cause_render_common_suites.ml`
(both forms per case):

1. `Concurrent [Fail; Interrupt]` — one-pager case.
2. `Suppressed {Fail; Die}` — one-pager case.
3. nested `Finalizer (Sequential [Fail; Die; Interrupt(id)])` — one-pager case.
4. anonymous vs identified interrupts — one-pager case.
5. multi-defect `Concurrent [Die; Die]` — one-pager case.
6. `Suppressed × Concurrent × Finalizer` ugly composite.
7. mixed nesting parenthesization (`(a + b) ; fail(C:3)`).
8. suppressed-primary-suppressed (`(a | suppressed: f1) | suppressed: f2`).
9. newline sanitization (`\n` payloads in typed + finalizer leaves).
10. degenerate raw composites (`Sequential []`, singletons).

Property: ~380 enumerated causes, no `\n`/`\r`, non-empty output.
Encoder snapshots: 5 exact-JSON cases in
`test/otel_common/cause_json_common_suites.ml`.

## Census / footgun vs sealed predictions

| Metric | Sealed | Actual | Score |
|---|---|---|---|
| Core vals | +1 (`pp_compact`) | +2 (`pp_compact`, `interrupt_id_to_int`) | **miss** — encoder forced the accessor; alternatives (encode all ids `null`, scrape `Cause.pp`) rejected as lies/fragile |
| `eta_otel` modules | +1 (`Cause_json`) | +1 | hit |
| Footguns | +0/−0 | +0/−0 | hit |
| Kill gate | does not fire | does not fire (red-team evidence) | hit |
| Board ratings | PASS all five, case 3 PASS-with-comment | pending board | — |

## Red-team

`.scratch/research/dx/e4/redteam/` — four monsters: everything-at-once
(suppressed × concurrent × sequential × finalizer × nested suppressed,
multi-line payloads), degenerate composites, metadata-omission check,
parens-in-payloads. All programmatic checks passed: one line holds, all 11
leaves of monster1 present, omission is contracted not silent, `pretty`
retains what compact omits. Key structural finding: the parenthesization
rule is what preserves the primary/finalizer distinction — `| suppressed:`
binds loosest and suppressed children under seq/conc are always
parenthesized, so an unparenthesized trailing `| suppressed:` is
unambiguously the top node.

## Self-assessment against the kill gate

If I had to argue for killing `pp_compact`: monster1's compact line is 260+
characters, and at that depth a human scans rather than reads — but the
corpus cases that matter (span statuses, log fields, exits of real fibers)
look like cases 1–6, all ≤ 80 characters, all preserving the distinction.
The kill gate asks whether compactness destroys the primary/finalizer
distinction; the red-team shows it does not. I do **not** kill the
one-liner. Final call belongs to the board (QUESTIONS.md item 6).

## Per-piece recommendation

| Piece | Recommendation | Basis |
|---|---|---|
| `Cause.pp_compact` | **Promote** | gates green; property + corpus machine-checked; red-team truthful; kill gate does not fire on my evidence |
| Snapshot corpus | **Promote** | 10 locked both-ways cases + newline-freedom property; drift fails `dune runtest` |
| `Eta_otel.Cause_json` | **Promote** | 5 locked JSON snapshots; core JSON-free; fills the structured-encoding gap the census miss paid for |

## Deviations from objective

1. Expect tests use Alcotest exact-string checks (repo convention per
   `test_cause_pretty`), not ppx_expect — no new dependency, same drift
   failure semantics.
2. Census sealed +1 core val; shipped +2. Recorded as a prediction miss
   with the forcing evidence (encoder needs interrupt identity).

---

## Rework round 1 — board kill gate fired on cases 2 & 6

### Board evidence (verbatim)

The error review board rated the corpus: cases 1, 3, 4, 5
PASS-WITH-COMMENT; **cases 2 and 6 FAIL**:

> The one-line form `p | suppressed: f` never says the right-hand cause ran
> in a **finalizer**. For a reader, "suppressed" can mean an arbitrary
> secondary error. The tree form labels `finalizer:`; the compact form
> loses that role.

The pre-registered kill gate fired; the orchestrator authorized one rework
round. My sealed prediction ("kill gate does not fire") and my red-team
claim ("the paren rule is what preserves the primary/finalizer
distinction") were both wrong in the same way: they covered *structural*
distinction, not *role naming*. Recorded as a prediction miss.

### Fix and re-locked corpus

Notation: `p | suppressed: finalizer(f)` — the finalizer role is explicit
in the suppressed segment, reusing the existing `finalizer(...)`
vocabulary; the wrapper self-delimits, so composite finalizer sides drop
their old parens. Updated in `cause.ml` (dead `` `Sup `` paren row removed)
and the `cause.mli` legend.

Re-locked snapshots (pretty forms unchanged):

- corpus 2: `fail(B) | suppressed: finalizer(die(Invalid_argument("cleanup")))`
- corpus 6: `fail(A) + die(Failure("boom")) | suppressed: finalizer(fail("cleanup failed") ; interrupt)`
- corpus 8: `(fail(A) | suppressed: finalizer(fail("f1"))) | suppressed: finalizer(fail("f2"))`
- red-team `output.txt` regenerated; all programmatic checks still pass;
  review-packet case files regenerated.

### Gates (rework) — all green

`dune build @install`, `dune runtest --force`, `eta-oxcaml-test-shipped`,
mainline `dune build test/cache_jsoo test/js_jsoo`.

### Housekeeping

Committed generator artifacts (`gen_renders.cmi/.cmx/.o`) removed from
git; `.gitignore` extended; `gen.sh` cleans them after each run.

### Worse than two lines?

No. Fixed corpus lines are 68–82 characters with the role explicit at the
point of suppression; the monster line grows but stays parseable because
each `finalizer(...)` self-delimits. I hold the rework verdict: the
one-liner earned its keep. The kill/power decision now belongs to the
continuity board plus a cold reviewer on the revised packet.

### Updated recommendation

| Piece | Recommendation | Basis |
|---|---|---|
| `Cause.pp_compact` (reworked) | **Promote, pending continuity review** | kill-gate failure was actionable and is fixed in the notation; gates green; red-team re-run clean |
| Snapshot corpus (re-locked) | **Promote** | same machine checks; board re-rates the fixed renders |
| `Eta_otel.Cause_json` | **Promote** (unaffected) | board failure was notation-only |
