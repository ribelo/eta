# Observer order counterexample

Type: prototype
Status: resolved
Blocked by: none

## Question

Does the current observer comparator fail to define a total order on a dynamic
graph, as N3 claims?

Build the `A`, `B`, and `C` graph from the independent review. Enumerate observer
registration orders and relevant creation orders. Record comparator relations,
delivery orders, and whether any delivery violates a dependency-first promise.

Compare deterministic observer-identity order with one explicit topological
delivery plan. Do not implement either production policy. Link the prototype as
an asset.

## Answer

Yes. N3 reproduces, and the current comparator does not define a total order.

After the bind switch, the exact graph has signal IDs `A < C < B`. The
production comparator reports these relations:

```text
A > B
A < C
B > C
```

Thus, the strict relation is `A < C < B < A`.

### Delivery matrix

The probe runs all six observer-registration orders. The cyclic graph produces
three callback orders:

| Registration order | Callback order | `B` before `A` |
| --- | --- | --- |
| `A,B,C` | `C,B,A` | yes |
| `A,C,B` | `C,B,A` | yes |
| `B,A,C` | `A,C,B` | no |
| `B,C,A` | `A,C,B` | no |
| `C,A,B` | `B,A,C` | yes |
| `C,B,A` | `B,A,C` | yes |

The current OCaml `List.sort` result therefore depends on observer-registration
order. Two cases deliver the bind owner `A` before its selected dependency `B`.

### Creation-order controls

The probe also places unrelated `C` outside the ID interval between `A` and
`B`.

- `C < A < B` produces `C,B,A` for all six registration orders.
- `A < B < C` produces `B,A,C` for all six registration orders.

Both controls define transitive relations. Registration order changes delivery
only when unrelated `C` has the intervening ID that closes the comparison
cycle.

### Policy controls

Observer-identity order is the registration order. It always defines a total
order. It delivers `A` before `B` in three of the six registration orders.

The explicit topological plan makes `B` a prerequisite of `A`. It uses observer
identity to choose between ready observers. All six plans deliver `B` before
`A`.

Neither control is a production decision. [Observer delivery
contract](11-observer-delivery-contract.md) owns the choice between identity
order and a topological plan. It also owns the public law.

### Evidence

The prototype is on branch `prototype/eta-signal-observer-order` at commit
`b3b6e60d`. Run it with one command:

```sh
bash .scratch/prototypes/eta-signal-observer-order/run.sh
```

The command exits with status `0` only when the exact graph forms the cycle and
both creation-order controls stay acyclic.

- [Probe results](../../../../.scratch/research/eta-signal-direction/observer-order-counterexample/RESULTS.md)

### Census rows resolved here

The prototype confirms `EXE-011`, `N03-002` through `N03-008`, and `N03-019`.

It amends `N03-009`. The current runtime produces three orders across input
arrangements. The probe does not compare different standard-library
implementations. The failed comparator precondition is sufficient to reject
`List.sort` output as a semantic contract.
