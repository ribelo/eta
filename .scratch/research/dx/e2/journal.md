# DX-E2 Journal — `discard` + generalized `ignore_errors`

Branch: `research/dx-e1e2e3-hygiene`
Phase: B (hygiene)

Sealed predictions: `.scratch/research/dx/journal.md` §E2.

## Implementation

- Deleted `Effect.ignore`.
- Added `Effect.discard = map (fun _ -> ())`.
- Generalized `ignore_errors` to `('a, 'err1) t -> (unit, 'err2) t` via
  `bind_error (fun _ -> unit) (discard eff)`.
- Split the seven old `ignore` behavior checks into `discard` tests (value
  discard; typed/defect/interrupt/finalizer propagate) and expanded
  `ignore_errors` tests (value discard + typed suppress; other causes visible).
- No production `Effect.ignore` call sites; existing `ignore_errors` unit sites
  remain source-compatible.
- CHANGELOG idiom-pass entry extended at the marked E2 point.

## Hold gate

Migration was 100% behavior tests of the combined swallow meaning — not pure
value-discard production use. **No hold.**

## Gates

All required Nix gates PASS (see report).
