# DX-E9 Red-team verdict

## Bug the old shape invited

`implicit_race.ml`: order-sensitive ledger transfer written as

```ocaml
let open Eta.Syntax in
let* () = Db.write debit …
and* () = Db.write credit … in
```

Author intent: sequential debit-then-credit. Old `Syntax.and*` = `Effect.par`
→ both writes fork; first failure cancels the sibling; interleaving is legal.
Silent race; no intent signal at the open.

## New shape

`explicit_sequential.ml`:

```ocaml
let open Eta.Syntax in
let open Eta.Syntax.Applicative in
let* () = Db.write debit …
and* () = Db.write credit … in
```

- Open declares sequential product.
- Left settles before right starts (suite: `syntax Applicative right waits for left`).
- Left failure skips right (suite: `syntax Applicative fail-fast skips right`).
- Nothing is forked.

If the author truly wants concurrency, they must `open Syntax.Parallel` — the
declaration is the intent signal the old always-open form lacked.

## Distinctness

`distinctness.ml` + suite cases Effect 55–61: same `let* … and* …` surface under
each module differs observably (ordered log / right-waits vs par fail-fast).

## Verdict

**PASS.** Old shape silently races order-sensitive writes. New shape forces an
explicit open; Applicative is sequentially correct; Parallel keeps today's par
semantics under a named open.

This demonstrates the footgun fix. It does **not** by itself prove the
comprehension gate (independent review measures that).
