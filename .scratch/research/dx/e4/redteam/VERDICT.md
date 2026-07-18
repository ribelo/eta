# E4 red-team verdict — `pp_compact` under adversarial causes

Probe: `probe_compact_monster.ml` (build/run: `bash build.sh` from the repo
root inside `nix develop`; compiles against the main workspace `lib/eta`
build, not the possibly stale switch-installed `eta`).
Raw output: `output.txt`.

## What was attacked

1. **monster1 — everything at once.** Suppressed × Concurrent × Sequential ×
   Finalizer × nested Suppressed, anonymous and identified interrupts,
   multi-line payloads (`"metrics flush failed\nwith detail"`,
   `Failure "finalizer exploded\nover lines"`).
2. **monster2 — degenerate composites.** Raw `Sequential []`, raw
   `Concurrent [leaf]` singleton, `Finalizer (Sequential [])`.
3. **monster3 — metadata omission.** A `Die` carrying `span_name` and
   annotations: compact must omit them, `pretty` must keep them.
4. **monster4 — parens in payloads.** `fail "unbalanced ) paren"` and
   `fail "another ("`.

## Findings

- **One line holds.** All four monsters render without a raw `\n` or `\r`;
  payload newlines are escaped to literal `\n` two-character sequences.
  (The exhaustive enumeration in `test/core_common` covers the same property
  over ~380 generated causes.)
- **Truthful structurally.** Programmatic leaf checks: every one of
  monster1's 11 leaf payloads appears in the compact line exactly where its
  tree position says it should. No node kind is dropped; degenerate raw
  composites render honestly as `sequential()` / `concurrent()`.
- **The paren rule is what saves the primary/finalizer distinction.**
  `| suppressed:` binds loosest, and a `Suppressed` child under
  `Sequential`/`Concurrent` is always parenthesized, so an unparenthesized
  trailing ` | suppressed: X` can only be the top node. Example from
  monster1: `fail(auth) ; interrupt#1 | suppressed: (...)` reads as
  `Suppressed { primary = Sequential [fail auth; interrupt#1]; ... }`; the
  alternative parse would require parens the renderer would have emitted.
  The distinction survives compactness — the kill gate does **not** fire on
  this evidence.
- **Omission is contracted, not silent.** monster3: compact renders
  `die(Failure("export boom"))` and drops span/annotations; `pretty` keeps
  them. The mli contract states the omission and points to `pretty`.
- **Not machine-parseable.** monster4: `fail(unbalanced ) paren)` — payload
  parens render raw (same as `pretty`'s `fail: unbalanced ) paren`).
  Compact is human-facing only; `Eta_otel.Cause_json` is the
  machine-facing encoding. Not a defect; recorded so the board sees the
  boundary explicitly.
- **Interrupt identity.** `interrupt` vs `interrupt#1` — anonymous stays
  visibly anonymous; identified ids correlate with `pretty`'s
  `interrupt: 1`.

## Pre-existing wart surfaced (not E4 scope)

`pretty` writes multi-line payloads raw, so `finalizer fail: metrics flush
failed\nwith detail` breaks indentation (see monster1 `pretty:` block,
unindented `with detail`). Acceptable for a multi-line renderer; noted as a
follow-up candidate, not changed here.

## Verdict

`pp_compact` stays one line and stays truthful on the ugliest causes I could
construct. No omission beyond the contracted defect-metadata summary. I would
not kill the one-liner; the corpus is ready for board rating.

---

## Rework round 1 — board kill-gate fix (suppressed notation)

The board failed corpus cases 2 and 6 on the *role* question: the old
`p | suppressed: f` line never said the right-hand side ran in a finalizer.
That verdict supersedes my claim above that the paren rule alone "saves the
primary/finalizer distinction" — the distinction survived, the role label
did not.

Fix: `p | suppressed: finalizer(f)`. `output.txt` regenerated:

- monster1 now has three `| suppressed: finalizer(...)` points, each
  self-delimited (composite finalizer sides no longer need parens); all 11
  leaf checks still pass, still one line.
- monster3/monster4 unaffected; monster2 unaffected.

Line-length cost on monster1: ~260 → ~330 characters. Readability cost on
the corpus cases that matter (≤ 82 chars): negligible, and the role is
explicit. The red-team verdict stands with the fixed notation.
