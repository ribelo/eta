# DX-E24 red-team verdicts

## A. Nonpositive explicit bounds

Probe: `invalid-bounds.ml`.

Promoted executable evidence:
`test/core_common/effect_common_suites.ml` test
`map_par rejects nonpositive max`. Construction with both zero and a negative
bound raises:

```text
Invalid_argument("Effect.map_par: max_concurrent must be > 0")
```

The E24 red-team source uses `0` and `-3`; the parity test covers both classes at
construction time. No mapper or runtime is needed to trigger the error.

**Verdict:** PASS — invalid bounds fail loudly and cannot become the default or
an unbounded execution mode.

## B. Omission that looks unbounded

Probe: `default-cap.ml`.

Promoted executable evidence:
`test/core_common/effect_common_suites.ml` test
`map_par default cap is eight`. Nine delayed inputs reach a measured peak of
exactly eight active mapper effects; the ninth starts only after the first wave
settles. The optional-erasure test also proves omission yields an `Effect.t`,
not a partial function.

The call `Effect.map_par fetch ids` can still be guessed incorrectly in
isolation. The public contract now says “the default is 8” and
`docs/api-dx.md` repeats “Omission does not mean unbounded concurrency.”

**Verdict:** PASS — runtime behavior is capped at eight and the mli sentence is
direct enough to correct the likely misreading. The visual call alone does not
communicate the cap; documentation remains necessary.
