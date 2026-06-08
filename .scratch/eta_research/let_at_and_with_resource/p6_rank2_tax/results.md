# P6 Rank-2 Inconsistency Tax

`Supervisor.scoped` remains rank-2 and cannot be flattened by `let@` without losing the phantom scope guarantee. The lab quantified whether this inconsistency commonly mixes with `let@`-eligible resource callbacks in the same body.

## Search Commands

```text
rg -n "Eta\.Supervisor\.scoped|Supervisor\.scoped" lib test -g '*.ml'
rg -n "Eta\.Supervisor\.scoped|Supervisor\.scoped|with_background|with_resource|with_permits" lib test -g '*.ml' | cut -d: -f1 | sort | uniq -c
```

## Results

Supervisor scoped call sites found:

- `lib/stream/eta_stream.ml`: 3
- `test/eta/test_eta_supervisor.ml`: 9
- `test/eta/test_eta_observability.ml`: 1
- `test/http/test_eta_http_h2_writer.ml`: 1
- `test/sql/test_sql.ml`: 1

Mixed bodies where a rank-2 supervisor appears in the same function as a resource/lifecycle primitive:

- `lib/stream/eta_stream.ml` merge path uses `Eta.Effect.acquire_release` in producer setup and `Eta.Supervisor.scoped` for child ownership in the same function family.
- The test files use supervisor scopes as direct subjects, not as mixed `with_*` ladders.

No real code site was found that alternates `let@ x = with_thing in` with `Supervisor.scoped { ... }` in the same visual ladder. The synthetic consumer fixture also does not mix supervisor scoping.

Verdict: rank-2 inconsistency tax is low. Documentation should say that `Supervisor.scoped` is intentionally different: its body is rank-2 to prevent child escape, and `let@` is only for ordinary CPS `with_*` functions.
