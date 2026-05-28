# P3 Soundness Results

Command:

```text
nix develop -c bash scratch/eta_research/let_at_and_with_resource/p3_soundness/run.sh _build/default/lib/eta/eta.cmxa
```

Result:

```text
letat_effect_domain_safe_spawn_negative.ml PASS compile-fail
Error: The value "effect" is "nonportable"
       but is expected to be "portable"

letat_local_borrow_capture_negative.ml PASS compile-fail
Error: This value is "local"
       but is expected to be "local" to the parent region or "global"

letat_local_borrow_escape_negative.ml PASS compile-fail
Error: This value is "local"
       but is expected to be "local" to the parent region or "global"

letat_pool_domain_safe_spawn_negative.ml PASS compile-fail
Error: The value "effect" is "nonportable"
       but is expected to be "portable"

letat_unique_double_use_negative.ml PASS compile-fail
Error: This value is "local"
       but is expected to be "local" to the parent region or "global"

unique_double_use_core_negative.ml PASS compile-fail
Error: This value is used here, but it has already been used as unique

with_resource_portable_atomic_negative.ml PASS compile-fail
Error: This value is "nonportable"
       but is expected to be "portable"
```

Full command output included the expected `Domain.Safe.spawn` advisory alerts and package deprecation warning for `mtime.clock.os`; those are not the rejection reason.

## Fixture Meaning

The nonportable Eta-effect fixtures are positive controls: Eta effects are already nonportable without `let@`. Their value here is showing that `let@` and the CPS companion do not relax those existing gates.

| Fixture | Claim tested | Result |
| --- | --- | --- |
| `letat_effect_domain_safe_spawn_negative.ml` | A `let@`-flattened CPS resource effect cannot be captured by `Domain.Safe.spawn`. | Rejected as nonportable. |
| `letat_local_borrow_capture_negative.ml` | A CPS function carrying a local unique borrow cannot capture that borrow in a lazy Eta effect closure. | Rejected at the local boundary. |
| `letat_local_borrow_escape_negative.ml` | A CPS function carrying a local unique borrow cannot return the borrow through Eta effect success. | Rejected at the local boundary. |
| `letat_pool_domain_safe_spawn_negative.ml` | `let@` over existing `Pool.with_resource` does not make the resulting Eta effect portable. | Rejected as nonportable. |
| `letat_unique_double_use_negative.ml` | A naive CPS resource function carrying a local unique borrow cannot even hand the local borrow to an effectful callback in tail position. | Rejected at the local boundary before double-use can occur. |
| `unique_double_use_core_negative.ml` | OxCaml still rejects a unique value consumed twice. | Rejected as already used unique. |
| `with_resource_portable_atomic_negative.ml` | A CPS companion implemented over `Effect.acquire_release` preserves Eta effect nonportability when published through `Portable.Atomic`. | Rejected as nonportable. |

Verdict: P3 preserves the current soundness gates. `let@` is syntax over CPS functions, not a runtime ownership primitive; the mode checker continues to reject the same nonportable, local, and unique crossings.
