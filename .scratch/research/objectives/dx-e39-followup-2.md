# Follow-up 2: DX-E39 — two narrow fixes before promotion

The reviewer of record verified S′ closes all three original findings and
judged the library design correct. Two narrow issues remain — both
mechanical, both precisely specified. No new sealed predictions needed;
record the work as a short journal note.

## Fix 1 — benchmark sink: back to the safe fingerprint

`bench/effect_construction/construction_sink.ml:9` currently fingerprints
with `String.length (Effect.describe eff)`. Under the documented
`--filter` workflow (e.g. `--quick --filter 'effect.construction.map_bind$'`)
the sink retains the 10,000-layer `map_bind` blueprint, and `describe`
would attempt ~400M spaces of indentation in quick mode (~40 GB in full
mode) — stack exhaustion or OOM. The unfiltered measurement runs never
trigger it only because the final mixed workload overwrites the sink with
an opaque `Custom`.

Restore R's shape: fingerprint with `Effect.name` (safe — reads the leaf
label only). Fingerprinting happens after the measured rows, so BEFORE/S
timing comparability is unaffected. Keep the D7 consumer-map entry as
historical evidence (the `describe` sink existed at the measurement point;
that is what made BEFORE/S comparable). Update the addendum's sink
paragraph to record this fix and why comparability still holds.

## Fix 2 — R166b needs a `Map` witness

`test/effect_introspection/test_effect_describe.ml` proves `describe`
does not invoke `Custom.eval` or `Bind.k`, but never exercises a
side-effectful `Map` function — while law row R166b claims `describe`
does not evaluate the blueprint generally. Per the repository law policy
(every side of a claim exercised), add a `map_forced` witness: a `Map`
whose function would set a ref/flag if invoked; assert the flag stays
false after describing `Map\n  Pure`. Registry row text likely unchanged —
the point is the coverage gap closes.

## Gates

Re-run after both fixes: the native trio plus the focused
`nix develop -c dune runtest test/effect_introspection --force`, and the
mainline JS targets (`--build-dir=_build-mainline`). Status files under
`evidence/gates-sprime/` (overwrite or add `-final` suffixed files, your
choice — keep the earlier ones).

## Report

Short append to `report.md`: the two fixes, the new gate results, one
line on the sink/comparability reasoning.

## Done means

Same signals: `E39 READY FOR REVIEW` / `E39 BLOCKED: <reason>` /
`E39 STOP: <§4.6>`. Same scope fence. This file stays uncommitted.
