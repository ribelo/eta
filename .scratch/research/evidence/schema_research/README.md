# schema_research

Lab for the Effet schema / decode / validation research entry.

The shared fixture is in `fixture.ml`. It translates a curated subset of
Effect-TS Schema behaviours into a tiny JSON-like OCaml value model:

- decode unknown JSON into typed values with path-aware issues;
- encode typed values back to JSON;
- struct, array, optional field, literal/union composition;
- refinement checks such as `minLength` and `between`;
- branded values;
- bidirectional transformations such as finite number from string;
- effectful decode through `Effet.Effect.t`;
- JSON Schema document shape, arbitrary samples, and equivalence.

Candidates:

- `h_s0_skip.ml` documents the "ship nothing" hypothesis as a runnable support
  report.
- `h_s1_decode.ml` models a minimal `Effet.Decode` wrapper over existing
  parsers.
- `h_s2_decode_validate.ml` adds validation and branded values.
- `h_s3_schema_gadt.ml` tests a first-class schema GADT.
- `h_s4_ppx_schema.ml` tests a GADT/metadata layer over ppx-generated codecs.
- `h_s5_codec_record.ml` tests the discovered "codec record" alternative,
  close to `data-encoding`.

Run positives:

```sh
nix develop -c dune build .scratch/research/evidence/schema_research/
nix develop -c dune exec .scratch/research/evidence/schema_research/runtime_smoke.exe
nix develop -c dune exec .scratch/research/evidence/schema_research/migration_smoke.exe
```

Negative tests are intentionally not in the `(modules ...)` list. Add one
negative module stem to `.scratch/research/evidence/schema_research/dune`, run the build, capture
the compiler error, then remove it.

Second-pass files:

- `migration_fixture.ml` — schema-heavy mini app: branded values, nested
  records, tagged unions, recursive menu tree, transform, all-error reporting,
  policy-dependent decode.
- `m_a_pure_schema_effect_policy.ml` — pure schema values plus effectful decode
  policy. This is the recommended direction.
- `m_b_env_codec_record.ml` — env-tracking codec record. It works, but codec
  values must be thunked.
- `m_c_module_first.ml` — module-first facade over M-A, matching idiomatic
  OCaml domain modules.
- `STUB_schema.mli` — proposed future `effet-schema` contract.
- `BACKLOG_SCHEMA.md` — first implementation slices if the package is promoted.
