# Follow-up 1: DX-E24d — two findings

Review verdict: CORRECT-WITH-RESERVATIONS. Two fixes, both small.

## 1. MEDIUM: empty composite must pass through, not defect

`lib/eta/effect_schedule.ml` (~line 58): `None -> invalid_arg
"Effect.retry: empty composite cause"` introduces a new failure mode.
`Cause.t`'s variants are public; only the smart constructors document
rejecting empties; the repo tests rendering of raw empty composites
(`test/core_common/cause_render_common_suites.ml:155-159`), so "malformed"
is not a documented invariant of every `Cause.t`. The pre-alignment code
passed such causes through unchanged (`Exit.Error _ as err -> err`), and
your own four rules say "no typed failure → no policy, original cause
unchanged".

Change `None -> invalid_arg ...` to `None -> error cause`. Add one named
test: a raw `Cause.Sequential []` (constructed via the public variant)
passes through `retry` unchanged — no policy run, no defect, original
cause returned. Update the mli sentence if it implies the invariant.

(If you believe the non-empty invariant SHOULD exist library-wide, that
is a separate experiment proposal for the journal — not something `retry`
unilaterally enforces in a corner of the API.)

## 2. LOW: stale E22 registration spans

`.scratch/research/dx/e22/review/LAWS.md`: R94 points at `:974-975`,
R100 at `:950-963`, R101 at `:964-971` — all stale after the added tests.
Correct spans: R94 → `:1158-1159`, R100 → `:1134-1147`, R101 →
`:1148-1155`. Verify by reading the files at those spans (and re-check
R79–R82 while you're there).

## Records and gates

Journal: append-only entry. Report updated (the edge note now reads
"passes through, matching the shared boundary's no-typed-failure rule").
Gates: native trio; mainline `test/laws`.

## Done means

`E24D READY FOR REVIEW` / `E24D BLOCKED: <reason>` / `E24D STOP: <§4.6>`.
Same scope fence. This file stays uncommitted.
