# DX-E31 `Effect.fn __POS__ __FUNCTION__` census

## Counting rule

The E10 comparison counts authored executable OCaml call sites (`*.ml`) under
`lib/ test/ examples/ bench/ http-testsuite/ drivers/`. Under that same rule,
the current tree has **4 sites in 2 files**, matching the orchestrator's
measurement.

Reproduction:

```sh
rg -n -U --glob '*.ml' \
  'Effect\.fn\s+__POS__\s+__FUNCTION__' \
  lib test examples bench http-testsuite drivers
```

## Executable-site table

| # | Source | Role | Consumer-shaped? | E10 sugar-eligible? | Why |
| ---: | --- | --- | --- | --- | --- |
| 1 | `test/ppx_common/ppx_common_suites.ml:117` | Hand-written `Ok` parity oracle for `[%eta.result]` | No — PPX framework test | **No** | Local value binding `result_hand_ok`, not a function binding; E10 rejects non-function bindings. |
| 2 | `test/ppx_common/ppx_common_suites.ml:124` | Hand-written typed-error parity oracle for `[%eta.result]` | No — PPX framework test | **No** | Local value binding `result_hand_err`, not a function binding. |
| 3 | `test/ppx_common/ppx_common_suites.ml:131` | Hand-written defect parity oracle for `[%eta.result]` | No — PPX framework test | **No** | Local value binding `result_hand_raise`, not a function binding. |
| 4 | `test/core_common/observability_common_suites.ml:123` | Direct `fn` name/location contract test | No — core framework test | **No** | Local value binding `program`, intentionally spells the primitive under test; not a function binding. |

Totals: **0 consumer-shaped**, **4 framework machinery**, **0 E10-sugar-eligible**.
The sealed eligibility prediction (4) was wrong: textual use of the expansion's
primitive is not equivalent to a definition site on which function-level sugar
can apply.

## Other textual matches (not executable-site census)

A raw all-file search finds two additional representations. They are listed so
“every site” is auditable, but are excluded from the E10-comparable 4/2 count:

| Location | Kind | Consumer-shaped? | E10 sugar-eligible? |
| --- | --- | --- | --- |
| `test/ppx_expansion/expected_expansions.txt:121` | Generated golden output for `[%eta.result]` | No — generated test artifact | No — it is output, not source |
| `lib/otel/README.md:66` | Application-shaped documentation example, bound as local value `work` | Yes, as prose/example | No — non-function binding |

The README is the only consumer-shaped position found by the broad textual
search. It demonstrates the existing explicit primitive and does not provide a
function-definition site that E10's forms could replace.

## Delta from E10's count of five

E10's hold branch contains the four current executable sites plus
`test/ppx_common/ppx_common_suites.ml:220`:

```ocaml
let hand_fn_add x = Effect.fn __POS__ __FUNCTION__ (Effect.pure (x + 1))
```

That fifth site is E10's own hand-written runtime-parity fixture and is the only
one eligible for function-level sugar. It did not land because E10 remained on
its hold branch. Therefore the current **5 → 4** delta is not adoption or
organic removal: it is the absence of E10's experiment-only fixture. The two
files remain the same, so the executable-site file delta is **2 → 2**, not the
sealed prediction of −1 file.

## Census verdict

The forcing-function-relevant number is not merely four rare sites; it is
**zero eligible consumer source sites**. The current executable uses are test
oracles for the primitive/other sugar, while the one broad-search consumer
example is also outside E10's function-binding shape.
