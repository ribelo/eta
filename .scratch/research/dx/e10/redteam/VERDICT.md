# DX-E10 Red-team verdict

## (a) Non-effect body under the sugar

Fixture: `non_effect_body.ml` (opaque `Effect.t` stub matching real `fn`).

Compiler output (`non_effect_body.txt`):

```
File ".../non_effect_body.ml", line 12, characters 15-16:
12 | let%eta f () = 1
                    ^
Error: This expression has type "int" but an expression was expected of type
         "('a, 'b) Eta.Effect.t"
```

Finding:

- Location points at the user body (`1`), not at ghost `fn` application text.
- Message is ordinary OCaml type error through `fn`'s third argument.
- Quality rating: **4 / 5** (honest, actionable; does not name `let%eta` but
  does not dump generated identifiers either).

Attribute twin (`test/type_errors/cases/ppx_eta_trace_non_effect_body.ml`)
points at the same body character under `[@@eta.trace]`.

## (b) `let rec` span semantics

Expansion (`let_rec_expansion.txt`):

```ocaml
let rec countdown n =
  Eta.Effect.fn __POS__ __FUNCTION__
    (if n <= 0 then Eta.Effect.pure () else countdown (n - 1))
```

Wrapper is **inside** the recursive body. Runtime evidence:
`test_let_eta_rec_spans` in `test/ppx_common/ppx_common_suites.ml` runs
`countdown 3` and expects **4** tracer spans (entries for n=3,2,1,0), each
named `countdown`.

Finding: spans are **per-call**, not once-per-definition. Document for
readers; this matches the sealed prediction and is not a defect.

## Overall

Red-team **2 / 2** obligations met. Error-location kill gate (≤ 3) **does not
fire**. Residual limitation: messages do not say "let%eta requires an effect
body" — they speak in `Effect.t` terms, which is correct for representation-
level sugar.
