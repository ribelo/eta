# DX-E9b Red-team Verdicts

## (a) Old invited bug — order-sensitive transfer under `and*`

Program: `transfer_and_star.ml` — debit then credit via

```ocaml
let* debited = debit amount
and* credited = credit amount in
...
```

**Verdict: PASS — observably sequential, correct by construction.**

Expected execution log (strict left-to-right):

```
debit:start → debit:10 → debit:done → credit:start → credit:10 → credit:done
```

Nothing is forked for the product; left failure would skip right (covered by
suite law `test_syntax_and_fail_fast_skips_right`). The old concurrent-`and*`
race is unwriteable at this spelling.

## (b) Wanted concurrency, used `and*`

Program: `wanted_concurrency_serialized.ml` — independent user/perms loads
spelled with `and*` instead of `Effect.par`.

**Verdict: PASS as perf-only residual surprise.**

Both effects run successfully, in order:

```
user:start → user:done → perms:start → perms:done
```

No sibling cancellation exists because nothing was forked. Values are correct;
the only cost is latency (serialization). Safety is preserved; performance is
not concurrent.

## (c) Docs-claim check

Command:

```sh
rg -n 'concurrent|fork|par ' lib/eta/syntax.mli
```

**Verdict: PASS.**

`syntax.mli` documents `and*`/`and+` as strict left-to-right product; nothing
forked; concurrency is redirected to `{!Effect.par}`. No remaining implication
that `and*` is concurrent.

## Summary

| Case | Outcome |
| --- | --- |
| (a) order-sensitive transfer + `and*` | sequential / correct by construction |
| (b) concurrency wanted + `and*` | correct-but-serialized (latency only) |
| (c) mli concurrency claim | none remaining |
