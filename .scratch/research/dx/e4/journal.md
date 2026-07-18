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
