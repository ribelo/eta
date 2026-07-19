# DX-E8 Red-team verdicts

## (a) Raising body → `Cause.Die` with span

Probe: `raise_body.ml` / `raise_body.txt`

```
span name=db.boom status=error:Failure("boom")
span name=Raise_body.program status=error:Failure("boom")
die=Failure("boom")
```

**Verdict: PASS.** Exception is not swallowed and not typed as `Fail`. It
surfaces as `Cause.Die` with both the leaf span (`db.boom`) and the outer `fn`
span marked error.

## (b) Sugar nested inside explicit `Effect.named`

Probe: `nested_named.ml` / `nested_named.txt`

```
span name=inner parent=1
span name=Nested_named.program parent=0
span name=outer parent=none
```

**Verdict: PASS (noisy-but-harmless).** Expansion still wraps `fn`+`named`, so
nesting under an outer `Effect.named "outer"` yields three spans (`outer`,
outer `fn` name from `__FUNCTION__`, and leaf `inner`). Documented; no runtime
guard added. Callers should not double-name the same leaf.

## (c) T9 audit — every identifier from use site or `__POS__`/`__FUNCTION__`

Probe: `expansion-t9.txt` (from `snapshot_expansions.sh` on `i_result.ml`)

```ocaml
Eta.Effect.fn __POS__ __FUNCTION__
  (Eta.Effect.named "db.find"
     (Eta.Effect.sync_result (fun () -> Db.find db id)))
```

| Identifier | Origin |
| --- | --- |
| `Eta.Effect.fn` / `named` / `sync_result` | fixed expansion template |
| `__POS__` | compiler use-site location |
| `__FUNCTION__` | compiler use-site function name |
| `"db.find"` | string literal at use site |
| `Db.find db id` | body expression at use site |
| `fun () ->` | mechanical thunk (no binder name from ambient scope) |

**Verdict: PASS.** No inferred names, no ambient policy, no fresh symbols.

## Summary

3 / 3 passed.
