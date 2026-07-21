# DX-E7b report

## Recommendation

**READY FOR REVIEW.** The deriver now supports matching structure and signature
generation for its documented contract: public, explicit-tag closed
polymorphic-variant aliases. The required gates and a fresh interface probe pass.

## Evidence

### V-DX-E7B-002 — signature generator and consumer

The pre-change paired consumer failed at `derived_error.mli` with:

```text
Error: Ppxlib.Deriving: 'eta_error' is not a supported signature type
       deriving generator
```

`lib/ppx/ppx_eta.ml` now registers both `str_type_decl` and `sig_type_decl`.
The signature generator emits:

```ocaml
val pp_err : Format.formatter -> err -> unit
```

`test/ppx_signature/derived_error.ml` and `derived_error.mli` derive the same
printer. `test/ppx_signature/consumer.ml` calls `Derived_error.pp_err`, so the
printer is compiled and used through the interface rather than only within the
implementation.

The finding-1 probe was also rerun in a fresh temporary directory. It compiled a
new derived `fresh.mli`, its matching `fresh.ml`, and a separate consumer, then
ran the consumer. Output:

```text
db:9
```

### V-DX-E7B-003 — render escape hatch

`test/ppx_expansion/cases/h_override.ml` now uses a record payload, which is not
a built-in payload, and supplies `[@eta.render pp_payload]`. Its pinned expansion
contains:

```ocaml
Format.fprintf __eta_fmt__001_ "custom:%a" pp_payload __eta_value__003_
```

`test/ppx_expansion/rejections/a_missing_override.ml` uses the same payload
without the attribute. The snapshot proves rejection identifies what and where
(`payload of tag `Custom in type err`) and what to do next (add
`[@eta.render My_type.pp]` or write `pp_err` manually).

### V-DX-E7B-004 — precise contract

`README.md` and `docs/api-dx.md` now state the supported declaration shape as a
public, explicit-tag closed polymorphic-variant alias and document the generated
`.mli` value. The generic rejection diagnostic and
`test/type_errors/expected_compile.txt` use the same precise contract. The
implementation still rejects private aliases, inherited rows, open/restricted
rows, and nominal variants; no payload or row support was expanded.

### V-DX-E7B-005 — example reversions

- `examples/map_projection.ml`: removed invented `` `Unexpected ``, its deriving
  annotation, and `pp_error` use.
- `examples/channel_probe.ml`: removed invented `` `Impossible ``, its deriving
  annotation, and `pp_error` use.

Neither example needs typed-error rendering, so each unexpected runtime error
branch now reports failure without inventing a typed error or printer.

## Gates

Run from `/tmp/Eta-dx-e7b` on `research/dx-e7b-eta-error-sig`:

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| Fresh `.mli` + `.ml` + separate consumer probe | PASS (`db:9`) |

The first full `runtest` run correctly exposed the old nominal-type diagnostic
snapshot. After updating that single directly coupled expectation, the exact
full gate was rerun and passed.

## Prediction score

1. **Signature generation — confirmed.** The signature value has the predicted
   name and type, and existing structure output remains unchanged.
2. **Consumer evidence — confirmed.** The paired interface failed before the
   generator and passes after it; a separate consumer uses `pp_err`.
3. **Render escape hatch — confirmed.** The record payload expands through `%a`;
   omission produces the predicted actionable rejection.
4. **Contract precision — confirmed.** This was a documentation and diagnostic
   correction only; unsupported declaration shapes remain unsupported.
5. **Example reversions — confirmed.** Both invented errors and printer wiring
   were deleted. No hand-written renderer was needed.
6. **Risk and gates — confirmed.** Signature AST construction was the only
   implementation-specific compile issue encountered; the focused checks and all
   required gates pass, and unchanged structure cases kept their symbol shape.

Score: **6/6 confirmed**.
