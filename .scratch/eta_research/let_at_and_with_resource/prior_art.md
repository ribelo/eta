# P0 Prior Art

P0 is orientation only. The verdict is based on P1-P3 first, then cross-checked here.

| Prior art | Shape | Maps to | Notes |
| --- | --- | --- | --- |
| Effect-TS `Effect.acquireRelease` and `Effect.acquireUseRelease` | Both value/scoped acquisition and acquire-use-release forms exist. | H-D/H-B prior art | Effect-TS supports both shapes, but its pipe/do notation differs from OCaml binding operators. Citation: https://effect.website/docs/resource-management/introduction/ |
| ZIO `ZIO.acquireReleaseWith` and `Scope` / `scoped` | CPS acquire-use-release and scoped resource values coexist. | H-D/H-E prior art | ZIO has first-class scope machinery and Scala for-comprehensions; Eta explicitly avoids importing the whole ecosystem shape. Citation: https://zio.dev/reference/resource/ |
| Cats Effect `Resource.use` | Resource is a first-class value consumed by CPS `use`. | H-B/H-E prior art | Strong resource abstraction, but heavier than Eta's current `Effect.acquire_release` value-returning primitive. Citation: https://typelevel.org/cats-effect/docs/std/resource |
| Containers `CCFun.let@` | Binding operator for callback inversion. | H-C/H-F prior art | Shows the operator is established OCaml vocabulary for CPS layout. Citation: https://c-cube.github.io/ocaml-containers/ |
| Eio `Switch.run`, `Net.with_tcp_connect` examples | Direct CPS `with_*` functions are common; examples often use callback layout. | H-A/H-C prior art | Eio keeps lifecycle in the callee and uses lexical callbacks; `let@` remains a layout choice, not RAII. Citation: https://github.com/ocaml-multicore/eio |
| Dream / Httpaf callback APIs | Callbacks are normal, but not uniformly resource-scoped `with_*`. | H-A prior art | Not decisive for Eta resource syntax. |

P7 cross-check: after P1b, the final verdict aligns with Effect-TS/ZIO on exposing both value/scoped acquisition and an acquire-use-release shape. Eta's project-specific choice is the name `Effect.with_resource` and the constraint that the companion is for body-bounded use; scope-end guard sites should stay with `Effect.acquire_release`.
