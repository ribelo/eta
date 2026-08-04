# Observer order: executable evidence for N3

## Question

Does the current observer comparator define a total order after an older bind
selects a later signal?

## Method

The probe constructs three observed signals:

- `A` is a bind owner.
- `B` is the later signal that `A` selects.
- `C` is unrelated to `A` and `B`.

The initial bind branch is a constant. The probe first initializes all three
observers. It then selects `B` and changes both `B` and `C` before one
stabilization.

This stabilization collects callbacks for `A`, `B`, and `C`. The staged bind
snapshot already selects `B` when callback sorting starts.

The probe runs three creation classes:

1. `C < A < B`.
2. `A < C < B`.
3. `A < B < C`.

Each class runs all six observer-registration orders. The observation boundary
is the idle graph after the callback phase finishes.

A branch-only function reports signal IDs and invokes the production graph
comparator. Public operations construct the graph, update sources, stabilize
the graph, and deliver callbacks.

The prototype is on branch `prototype/eta-signal-observer-order` at commit
`b3b6e60d`. One command runs it:

```sh
bash .scratch/prototypes/eta-signal-observer-order/run.sh
```

The command exits with status `0` only when the exact graph forms the cycle and
the two creation-order controls stay acyclic.

## Exact counterexample

The exact graph has these signal IDs:

```text
A = 5
C = 6
B = 7
```

The absolute values include internal graph nodes. Only their relative order is
part of the counterexample.

After `A` selects `B`, the comparator reports:

| Comparison | Result | Cause |
| --- | --- | --- |
| `A` against `B` | `A > B` | `A` depends on `B` |
| `A` against `C` | `A < C` | unrelated signal-ID order |
| `B` against `C` | `B > C` | unrelated signal-ID order |

These relations form `A < C < B < A`. Thus, the comparator is cyclic and is
not a total order.

## Observed callback delivery

The cyclic graph produces this matrix:

| Registration order | Callback order | Dependency first |
| --- | --- | --- |
| `A,B,C` | `C,B,A` | yes |
| `A,C,B` | `C,B,A` | yes |
| `B,A,C` | `A,C,B` | no |
| `B,C,A` | `A,C,B` | no |
| `C,A,B` | `B,A,C` | yes |
| `C,B,A` | `B,A,C` | yes |

The six input arrangements produce three callback orders. Two arrangements
deliver `A` before `B`, although `A` depends on `B`.

This result confirms the practical effect of the failed `List.sort`
precondition. The output is not one stable graph order across observer input
arrangements.

## Creation-order controls

The probe moves `C` outside the open ID interval between `A` and `B`.

### `C < A < B`

The comparator reports `A > B`, `A > C`, and `B > C`. All six registration
orders deliver `C,B,A`.

### `A < B < C`

The comparator reports `A > B`, `A < C`, and `B < C`. All six registration
orders deliver `B,A,C`.

Both controls are transitive. They are also independent of observer-registration
order. The cycle requires unrelated `C` to have an ID between bind owner `A`
and selected dependency `B`.

## Policy controls

The prototype compares two explicit plans. It does not implement either plan
in production.

### Observer-identity order

Observer IDs follow registration order. Therefore, identity delivery exactly
matches each registration order.

Identity order is total and deterministic for a fixed graph history. It places
`A` before `B` in three of the six registrations. Thus, it cannot also promise
dependency-first delivery.

### Topological order

The explicit plan treats `B` as a prerequisite of `A`. Both `B` and unrelated
`C` are initially ready. The plan uses observer identity to select among ready
observers.

The six plans are:

| Registration order | Topological order |
| --- | --- |
| `A,B,C` | `B,A,C` |
| `A,C,B` | `C,B,A` |
| `B,A,C` | `B,A,C` |
| `B,C,A` | `B,C,A` |
| `C,A,B` | `C,B,A` |
| `C,B,A` | `C,B,A` |

Each plan is total. Each plan also delivers `B` before `A`.

## Analysis

N3 reproduces. Dependency reachability plus unrelated signal-ID fallback does
not define a transitive pairwise relation.

The creation-order controls isolate the cause. Dependency precedence reverses
the `A` and `B` ID relation. The unrelated fallback retains both sides of the
intervening `C` relation. These rules close the cycle.

The current public `.mli` promises callbacks after a consistent snapshot. It
does not promise dependency-first callback delivery. The PRD describes
deterministic graph order, and existing tests require dependency-first delivery
in selected graphs.

Ticket 11 must decide the public contract. If it selects identity order, the
contract cannot include dependency-first delivery. If it selects dependency
order, one explicit topological plan must replace the pairwise comparator.

## Limits

The probe runs the current OCaml `List.sort` implementation. It does not compare
another standard library or compiler.

The probe changes private code only on its prototype branch. No introspection
function is part of the shipped library.

The graph contains one dynamic bind and one unrelated signal. More nodes are
not necessary to disprove transitivity.

The probe records callback order. It does not measure comparator work. Ticket
05 owns operation counts.

## Census rows resolved

Executable reproduction confirms `EXE-011`, `N03-002` through `N03-008`, and
`N03-019`.

The result amends `N03-009`. The current runtime produces three callback orders
across observer input arrangements. The failed comparator precondition rejects
the result as a semantic contract without a cross-implementation comparison.
