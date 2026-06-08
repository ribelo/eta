# P4 Naming Coverage

Naming candidates were evaluated after P1-P3. P1b re-opened the companion with direct-acquire evidence, so this table pins the accepted public name.

| Name | P1 call-site shape | Collision with `Pool.with_resource` | Grep ambiguity | Prior-art alignment | Verdict |
| --- | --- | --- | --- | --- | --- |
| `Effect.with_resource` | `let@ c = Effect.with_resource ~acquire ~release in ...` | Medium: shares name with `Pool.with_resource`, but module qualifier is clear. | Medium: `rg "with_resource"` returns both generic and pool-specific APIs. | Moderate: OCaml `with_*` convention. | Accepted. |
| `Effect.use` | `let@ c = Effect.use ~acquire ~release in ...` | Low. | High: `use` is too generic for grep and prose. | Moderate: Cats `Resource.use`; less direct for Eta. | Rejected. |
| `Effect.bracket` | `let@ c = Effect.bracket ~acquire ~release in ...` | Low. | Low. | Historical Haskell / Cats Effect term. | Rejected: names implementation pattern, not Eta user intent. |
| `Effect.acquire_use_release` | `let@ c = Effect.acquire_use_release ~acquire ~release in ...` | Low. | Low. | Strong Effect-TS / ZIO alignment. | Rejected for Eta: too long at call sites and imports foreign vocabulary. |
| Do nothing | Existing `Pool.with_resource pool @@ fun c -> ...`; downstream can use `let@`. | None. | None. | Aligns with small Eta surface. | Rejected by P1b direct-acquire evidence. |

P4 result: choose `Effect.with_resource`. It is the least surprising Eta/OCaml name, despite grep overlap with `Pool.with_resource`.
