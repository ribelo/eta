# Red-team C — Search for an intentional divergence

**Verdict: the “accidental” claim survived falsification.**

Searches run:

```sh
git log -p --follow -- lib/eta/effect_schedule.ml
git log --all -S'stripped_uncatchable' -- lib/eta/effect_core.ml
git log --all -S'first_typed_failure' -- lib/eta/effect_core.ml
git log --all --grep=retry -i
git log --all -G'bare.*Cause.Fail|composite.*retr|retry.*composite' -- \
  lib/eta test .scratch/research/dx/e22/review/LAWS.md
```

Evidence:

- The narrow `retry` match existed before the shared helper boundary; the
  implementation retained `Exit.Error (Cause.Fail err)` through later file
  splits and schedule refactors.
- `69adecfa` (`fix: address verified review findings`, 2026-06-02) introduced
  `stripped_uncatchable` and `first_typed_failure` specifically to repair
  composite recovery semantics.
- `bbe54cd9` (`feat: add retry_or_else fallback`, 2026-06-21) deliberately used
  those helpers and documented first-failure composite handling.
- `02efcaa5` moved both retry implementations into `effect_schedule.ml` without
  aligning them or recording a reason to keep them different.
- `365f7b01` later named bare-only `retry` a “Current limitation.” Its diff and
  the E24 record explain why the two-error `retry_or_else` API remains useful,
  but give no semantic reason for a narrower catchability boundary in `retry`.

No commit message, test, or contract identified a load-bearing caller that
depends on typed-only composites bypassing retry policy.
