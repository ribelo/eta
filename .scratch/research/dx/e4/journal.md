# DX-E4 Journal — Cause rendering: `pp_compact`, structured encoding, snapshot corpus

Branch: `research/dx-e4e5-cause-corpus-type-errors`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e4e5`
Phase: B (hygiene, batch 2) · effort M · risk low

## Predictions (sealed)

Sealed before any code or signature edits. Wrong predictions stay as data.

### Compact-notation sketch

Single line, ASCII only, **never** contains a newline regardless of input
(embedded payloads are newline-escaped; totality is part of the contract).

- `fail(<err>)` — typed failure. `<err>` is the caller's renderer output,
  inserted verbatim except newline sanitization (renderer owns its format,
  same convention as `pretty`'s `fail: <err>`).
- `die(<exn>)` — defect. `<exn>` is `Printexc.to_string`, newline-sanitized.
  Span name, annotations, and backtrace are **omitted by design**: compact is
  a summary line for span statuses and log fields; `pretty` and the JSON
  encoder own full diagnostics. The mli contract must say this loudly.
- `interrupt` / `interrupt#<id>` — anonymous / identified interruption.
- `a + b + c` — `Concurrent`. Unordered siblings; rendered left-to-right in
  cause order; same-flavor chains flatten.
- `a ; b ; c` — `Sequential`. Ordered; same-flavor chains flatten.
- Mixed nesting parenthesizes the child: `a ; (b + c)`.
- `finalizer(<f>)` — finalizer diagnostics; `<f>` uses the same grammar.
  `Finalizer.Fail` strings render quoted (`fail("cleanup failed")`, `%S`
  escaping) because they are raw payloads, not renderer output.
- `<p> | suppressed: <f>` — suppressed. Primary stays left of the labeled
  separator; finalizer diagnostics after it. `| suppressed:` is a labeled
  separator, not an infix operator, so a composite primary needs no parens.

Predicted renders (sketch, to be validated by the corpus):

| Cause | `pp_compact` |
|---|---|
| `Concurrent [Fail `A; Interrupt None]` | `fail(A) + interrupt` |
| `Suppressed {primary = Fail `B; finalizer = Die (Invalid_argument "cleanup")}` | `fail(B) \| suppressed: die(Invalid_argument("cleanup"))` |
| `Finalizer (Sequential [Fail "cleanup failed"; Interrupt (Some 1)])` | `finalizer(fail("cleanup failed") ; interrupt#1)` |
| `Interrupt None` vs `Interrupt (Some 7)` | `interrupt` vs `interrupt#7` |
| `Concurrent [Die (Failure "a"); Die (Failure "b")]` | `die(Failure("a")) + die(Failure("b"))` |

### Expected board ratings (what happened / where / what-next, no mli)

| Corpus case | Predicted verdict | Note |
|---|---|---|
| `Concurrent [Fail; Interrupt]` | PASS both forms | what = typed failure racing cancellation; next = inspect failure, find canceller |
| `Suppressed {Fail; Die}` | PASS both forms | primary/finalizer distinction survives compact |
| nested `Finalizer (Sequential …)` | PASS pretty; PASS-with-comment compact | longest line; `;` may read noisy |
| anonymous vs identified interrupt | PASS both | anonymous "who" is unknowable — same gap as `pretty`, not a compact regression |
| multi-defect composite | PASS both | exn messages carry the what |

### Kill gate

Predict the kill gate does **not** fire. The labeled ` | suppressed: `
separator keeps the primary leftmost and the finalizer side labeled, so
compactness does not destroy the primary/finalizer distinction. If the board
(or the red-team) shows the distinction dies on nested-suppressed monsters,
the honest finding is "two-line logs" and I will say so first.

### Structured encoding

`eta_otel` has **no** Cause encoding today (verified: zero `Cause` references
in `lib/otel/`). Add one public module `Eta_otel.Cause_json` over
`Cause.Portable.t` with a caller-supplied `'err` encoder; core stays
JSON-free. Node kinds: `fail`, `die`, `interrupt`, `sequential`,
`concurrent`, `finalizer`, `suppressed`. Deterministic key order for
snapshot tests (yojson assoc lists preserve insertion order).

### Census / footgun deltas

- Census: rendering/observability cluster **+1 val** (`Cause.pp_compact`);
  `eta_otel` **+1 public module** (`Cause_json`). No other surface change.
  Considered and rejected: `Cause.Portable.pp_compact` (out of one-pager
  scope; the JSON encoder is the portable-side story).
- Footgun: **+0/−0**. Candidate new trap: a user mistaking the compact line
  for complete diagnostics (defect metadata omitted). Mitigation: mli
  contract states the omission; flagged for the board, not counted as a
  footgun.

### Mechanical extras

- Newline-freedom: exhaustive generated corpus of cause trees (bounded
  depth, payloads containing `'\n'`, quotes, tabs) asserts `pp_compact`
  output contains no `'\n'`. No qcheck dependency; plain enumeration.
- Corpus minimum: the five one-pager cases rendered both ways
  (`pretty` + `pp_compact`) as exact-string expect checks in
  `test/core_common`, matching the existing `test_cause_pretty` convention.

### Gates

Predict green:

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo
```

`cause.mli` changes are pure OCaml; the jsoo track should compile unchanged.

### Promote/hold/kill prior (pre-evidence)

Predict **promote** all three pieces (`pp_compact`, corpus, encoder) if
gates are green and the red-team shows compact stays truthful under
nesting. Hold `pp_compact` only if the board verdict says the
primary/finalizer distinction is lost; the corpus and encoder promote
independently regardless.

---

## Execution log

### Step 1 — seal predictions

Committed this section before any code change
(`docs(dx-e4): seal predictions`).

### Step 2 — docs-first `.mli`

Wrote the `Cause.pp_compact` contract in `lib/eta/cause.mli` (9 doc lines:
segment shapes, parenthesization, suppressed separator, totality +
newline-freedom, the defect-metadata omission and where full diagnostics
live) before touching `cause.ml`.

### Step 3 — implement

- `lib/eta/cause.ml`: `pp_compact` as sealed. Two rec walkers (main tree +
  `Finalizer.t`) sharing `add_die` / `add_interrupt` / `add_join` helpers;
  parenthesization via a flavor context (`Seq`/`Conc`/`Sup`/`Sup_primary`/
  `Fin`/`Top`). Embedded renderer output and `Printexc.to_string` are
  sanitized (`\n`, `\r` → two-character escapes); `Finalizer.Fail` strings go
  through `%S`. Degenerate raw composites render as `sequential()` /
  `concurrent()`.
- OxCaml notes: `let add = Buffer.add_string buffer` (partial application)
  is local-moded and rejected inside closures passed to `List.iter`;
  eta-expanded to `let add text = ...`. A shared helper inside a `let rec
  ... and` group monomorphized on first use; lifted out as a plain
  polymorphic `let`.
- **Prediction miss (recorded as data):** the sealed census said +1 core
  val. `Eta_otel.Cause_json` needs interrupt identity for the `id` field,
  and `interrupt_id` had no accessor — encoding every id as `null` would
  merge distinct interruptors (a lie by omission), and scraping `Cause.pp`
  output is fragile. Added `Cause.interrupt_id_to_int`. **Actual core
  delta: +2 vals** (`pp_compact`, `interrupt_id_to_int`).
- `lib/otel/cause_json.ml` (private module, re-exported as
  `Eta_otel.Cause_json`): `to_yojson` / `to_string` over `Cause.Portable.t`
  with a caller `'err` encoder. Node kinds exactly as sealed; optional
  defect fields (`backtrace`, `span`, `annotations`) appear only when
  present; annotations encode as a list of `[key,value]` pairs (lossless
  under duplicate keys). Core stays JSON-free (verified: `lib/eta/dune` has
  no `libraries`).
- Corpus: `test/core_common/cause_render_common_suites.ml` — the five
  one-pager cases + four extra (suppressed × concurrent × finalizer, mixed
  nesting parens, suppressed-primary-suppressed, newline sanitization,
  degenerate raw composites), each locked both ways (`pretty` +
  `pp_compact`) as exact strings, registered in
  `core_common_suites.ml`. Interrupt-id expectations are assembled from
  single-node fragments through the function under test (ids are abstract,
  no literal can be written).
- Encoder snapshots: `test/otel_common/cause_json_common_suites.ml` — five
  exact-JSON cases, registered in `otel_common_suites.ml`.

### Step 4 — gates

```
nix develop -c dune build @install          # OK
nix develop -c dune runtest --force         # OK (515 core tests incl. 12 new; 30 otel incl. 5 new)
nix develop -c eta-oxcaml-test-shipped      # OK
nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo   # OK
```

jsoo build emits two pre-existing integer-overflow warnings in unrelated
js stubs; `cause.ml` compiles clean on the 5.4.1 mainline track.

### Step 5 — mechanical extras

- **Newline-freedom property:** exhaustive enumeration over ~380 generated
  causes (depth ≤ 2 composites over 8 main leaves + 6 finalizer leaves,
  payloads containing `'\n'`, quotes, tabs, empty strings; raw empty and
  singleton composites included) asserts no `'\n'` and no `'\r'` and
  non-empty output. In `cause_render_common_suites.ml` as
  `compact newline-freedom property`. No qcheck dependency added.
- **Census actual:** rendering/observability cluster **+2 vals**
  (`Cause.pp_compact`, `Cause.interrupt_id_to_int`) vs sealed +1 — the
  second val is the encoder-forced accessor described in step 3. `eta_otel`
  **+1 public module** (`Cause_json`), as sealed.
- **Footgun actual:** **+0/−0**, as sealed. The compact-is-a-summary
  omission is stated in the contract; monster4 in the red-team records that
  compact is not machine-parseable (the encoder is).

### Step 6 — red-team

`.scratch/research/dx/e4/redteam/` — `probe_compact_monster.ml` attacks the
renderer with: (1) suppressed × concurrent × sequential × finalizer ×
nested-suppressed with multi-line payloads; (2) raw empty/singleton
composites; (3) defect-metadata omission (compact must omit, `pretty` must
keep); (4) parens in payloads. Programmatic checks: one-line holds, all 11
monster-1 leaves present, no metadata leak, `pretty` retains metadata.
**All checks passed.** Key finding: the parenthesization rule is what
preserves the primary/finalizer distinction — `| suppressed:` binds loosest
and suppressed children under seq/conc are always parenthesized, so an
unparenthesized trailing `| suppressed:` is unambiguously the top node.
Kill gate does not fire. Full analysis in `redteam/VERDICT.md`.

### Step 7 — review packet

Files under `.scratch/research/dx/e4/review/` as required.

### Step 8 — report

See `report.md`.

### Follow-up notes (out of scope)

- `pretty` writes multi-line payloads raw, so a `Finalizer.Fail
  "line1\nline2"` breaks indentation (red-team monster1 `pretty:` block).
  Pre-existing; candidate for a future hygiene batch.
- `Cause.Portable.pp_compact` deliberately not added (sealed scope); the
  JSON encoder is the portable-side story. Revisit if a cross-domain sink
  asks for one-line text.
- `interrupt_id` arithmetic is now technically possible via
  `interrupt_id_to_int`; accepted as the price of structured encoding
  (the alternative — string scraping of `Cause.pp` — is worse).

---

## Rework round 1 — board fired the kill gate on cases 2 & 6

### Board evidence (verbatim)

The error review board rated the corpus: cases 1, 3, 4, 5
PASS-WITH-COMMENT; **cases 2 and 6 FAIL**. The failure is specific:

> The one-line form `p | suppressed: f` never says the right-hand cause ran
> in a **finalizer**. For a reader, "suppressed" can mean an arbitrary
> secondary error. The tree form labels `finalizer:`; the compact form
> loses that role.

The pre-registered kill gate ("compactness destroys the primary/finalizer
distinction") fired on this evidence. The orchestrator authorized **one
rework round**; if the fixed line reads worse than two lines, `pp_compact`
dies and "two-line logs" ships as the finding.

Board verdict vs my sealed prediction: I predicted the kill gate would not
fire, and argued in the red-team verdict that `| suppressed:` preserves
the primary/finalizer distinction. The board's reading is subtler and
correct: the *distinction* (which side is primary) survived, but the
*role* of the right-hand side (it ran in a finalizer) did not. Structural
paren-truth was not enough; the label itself was lossy. Recorded as a
prediction miss — my red-team checked parseability, not role naming.

### Fix

Spelling: `p | suppressed: finalizer(f)` — the suppressed segment now
wraps its right-hand side in the notation's existing `finalizer(...)`
vocabulary, so the reader names "this ran in a finalizer" from the line
alone. Implementation detail: the wrapper self-delimits, so composite
finalizer sides lose the parens the old form needed
(`... | suppressed: (a ; b)` → `... | suppressed: finalizer(a ; b)`); the
`` `Sup `` parenthesization row for the finalizer side was deleted (dead
rule), `` `Sup_primary `` is unchanged. mli legend updated.

Re-locked renders:

| Case | Fixed compact |
|---|---|
| corpus 2 | `fail(B) \| suppressed: finalizer(die(Invalid_argument("cleanup")))` |
| corpus 6 | `fail(A) + die(Failure("boom")) \| suppressed: finalizer(fail("cleanup failed") ; interrupt)` |
| corpus 8 | `(fail(A) \| suppressed: finalizer(fail("f1"))) \| suppressed: finalizer(fail("f2"))` |
| red-team monster1 | three suppression points, each `\| suppressed: finalizer(...)`, still one line, all 11 leaf checks pass |

### Gates (rework)

```
nix develop -c dune build @install          # OK
nix develop -c dune runtest --force         # OK (515 core incl. re-locked corpus)
nix develop -c eta-oxcaml-test-shipped      # OK
nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo   # OK
```

### Housekeeping

The review-packet generator's compile artifacts (`gen_renders.cmi/.cmx/.o`)
had been committed accidentally — `git rm`'d, `.gitignore` extended
(`_gen/`, `*.cmi`, `*.cmx`, `*.o`), and `gen.sh` now deletes them after
each run. Review-packet case files regenerated with the fixed notation.

### Self-assessment against the rework criterion

Does the fixed line read worse than two lines? For corpus cases 2 and 6
the fixed lines are 68 and 82 characters — longer than before but the role
is now explicit at the exact point the board asked for. Monster1's line
grows to ~330 characters with three `finalizer(...)` wrappers; it stays
parseable because each wrapper self-delimits. My verdict: better, not
worse — the notation earned its keep. Final call belongs to the
continuity board and the cold reviewer.
