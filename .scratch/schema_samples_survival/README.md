# Schema.samples Survival Research

Backlog: Effet-avf.

Current shipped behavior before removal:

| Constructor | Behavior | Survival result |
|---|---|---|
| primitives | small hand-written examples | useful only for smoke tests |
| array | `[ []; item.samples ]` | wrong shape pressure and poor coverage |
| option | `None :: Some samples` | reasonable but shallow |
| enum | all cases | reasonable |
| tagged_union | empty | unusable |
| lazy_ | empty | unusable for recursive schemas |
| record1..record6 | empty unless user supplies `?samples` | not derivation |
| transform | filters predecessor samples through decode | often empty |

Consumers:

- No non-test package code consumed `Schema.samples`.
- Tests did not rely on samples.

Decision:

- Remove `samples` from `Schema.t` and from the public API.
- Do not ship a half-implemented arbitrary/sample generator inside the core
  schema value.

Future direction:

- Add a companion `effet-schema-arbitrary` package only if users need it.
- That package should own capping, shrinking, recursion fuel, and property-test
  integration directly instead of hiding those policies inside `Schema.t`.
