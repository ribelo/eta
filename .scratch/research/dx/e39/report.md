# DX-E39 report — audit-slim race and S′ follow-up

## Outcome

Three reviewable endpoints now exist:

| Endpoint | Commit / range | Result |
| --- | --- | --- |
| S — slim | `7d8e5236..f136a68d` (code at `6c51b9e3`) | removes audit/footprints/declarations/assertions and `all` introspection special-casing; keeps `describe`/`collect_names` |
| R — remove | `f136a68d..82d17297` | additionally removes `describe`, `collect_names`, and propagated static names |
| S′ — describe-only | `f136a68d..563eef24` | keeps R's no-names two-field representation and restores only `describe` |

Independent review requested S′ because S's partial name propagation was
arbitrary while T5 requires a minimal printable blueprint. The adopted response
is [`dossier/addendum-sprime.md`](dossier/addendum-sprime.md). My final
recommendation is **promote S′**.

## Follow-up findings and resolution

1. **S's `collect_names` seam was indefensible.** At S, `race`, `par`, `par3`,
   `par4`, and `all_settled` aggregated child names while `all` no longer did.
   S′ retains R's full deletion: no `collect_names`, `Custom.names`, `?names`,
   `~names`, or `with_names`.
2. **`describe` is justified by T5, not demand.** The original dossier
   overstated the teaching/external-demand evidence. S′ restores the exact
   master contract and walker because a blueprint value remains minimally
   printable; the implementation adds no per-node representation.
3. **The consumer census missed the benchmark sink.** The pre-deletion
   `bench/effect_construction/construction_sink.ml:9` call was anti-elision
   infrastructure, not production demand. It is now D7 in the source audit and
   restored in S′ for benchmark comparability.

## Phase-0 evidence and cost

The corrected [source audit](evidence/source-audit.md) still finds no
in-repository production/runtime consumer of `audit`, `describe`,
`collect_names`, or the audit assertions; it cannot establish absence among
external consumers. It finds the raw-audit blocking boundary, dominant
self-tests, documentation references, and the corrected benchmark-infrastructure
call. Runtime tracing never read propagated `Custom.names`.

The pre-registered 100,000-iteration `map_bind_preserve` result remains:

- allocated words: 2,200,014 → 1,400,014 (**-36.36%**);
- warm-up-discarded median time: 6,357,551 ns → 2,879,977 ns (**-54.70%**);
- map/bind control allocation: 600,014 → 600,014 (**0.00%**).

The measured footprint win is shared by S, R, and S′. S′ additionally shares R's
removal of the static names field/sites; no R→S′ allocation claim is made.
Protocol and raw data remain in [the cost dossier](dossier/cost.md).

## S′ proof obligations

### Snapshot parity and representation

The restored S′ corpus is byte-identical to master:

```text
master e6ec8777dc5f12e27e57a1c5577147398aa81a83604c48c3bdd8404c308b457d
sprime e6ec8777dc5f12e27e57a1c5577147398aa81a83604c48c3bdd8404c308b457d
cmp=byte-identical
```

The exact master walker compiles against `Custom { eval; leaf_name }`; it reads
constructors plus `leaf_name` and no names aggregate. The new named test also
covers every documented label, indentation, trailing-newline absence, Bind
shape/continuation opacity, and custom/wrapper opacity.

Artifacts:
[`evidence/snapshot-parity-sprime.txt`](evidence/snapshot-parity-sprime.txt) and
[`evidence/representation-sprime.md`](evidence/representation-sprime.md). The
follow-up names-dependency stop condition was not met.

### Law registry, third pass

Rows R166a–R166h register each restored `describe` claim against the named Dune
snapshot alias and the exact constructor/opacity Alcotest case. The R disposition
is superseded only for `describe`; `collect_names` remains removed and
CD-E22-014 remains only `fn ~error_pp` debt. No audit, footprint, assertion, or
names-propagation row returned.

### Gates

All mandatory gates passed on all endpoints, including S′:

| Gate | S | R | S′ |
| --- | ---: | ---: | ---: |
| `nix develop -c dune build @install` | 0 | 0 | 0 |
| `nix develop -c dune runtest --force` | 0 | 0 | 0 |
| `nix develop -c eta-oxcaml-test-shipped` | 0 | 0 | 0 |
| mainline JS targets, dedicated `_build-mainline` | 0 | 0 | 0 |

Exact S′ commands/timestamps/statuses:
[`evidence/gates-sprime/`](evidence/gates-sprime/README.md).

## Prediction scores

The original sealed text remains unchanged. Independent review downgrades the
original `describe` consumer interpretation because snapshot/benchmark tooling
is not observed demand. Revised original subtotal: **6 hits, 2 partial/misses,
2 misses**.

- Hits: allocation direction and ≥10% threshold; timing direction; consumer
  classifications for audit and `collect_names`; tracing fault line.
- Partial/misses: assertion boundary use was actually raw `audit`; `describe`
  tooling existed, but the predicted teaching/demand interpretation was too
  strong.
- Misses: the 10–25% allocation and 5–15% timing brackets were too conservative.
- The original endpoint-winner prediction S was rejected by review and remains
  outside the falsifiable subtotal.

The appended `Amendment predictions (sealed)` section was committed before S′
code as `36d39c85`. Its three clusters all hit: exact snapshot/no-names proof,
exact describe-only law restoration, and exact S′ census. **Amendment subtotal:
3 hits, 0 partials, 0 misses.**

## Diff and census summary

Requested final ranges:

- `f136a68d..563eef24`: 44 files, +773/-290.
- merge-base `7d8e5236..563eef24`: 105 files, +2,075/-1,169.
- R provenance `82d17297..563eef24`: 26 files, +730/-12, including the
  intervening original dossier and sealed amendment.

S′ census:

- `Custom`: 2 fields (`eval`, `leaf_name`).
- Public aggregate/tree introspection: 1 value (`describe`); separate `name`
  remains.
- Audit assertions: 0.
- `Expert.make`: `?leaf_name` only; 0 aggregate-name/audit metadata parameters.
- Explicit `~names` storage sites under `lib/`: 0.

Exact commands, subsets, and the four-endpoint census are in
[`dossier/addendum-sprime.md`](dossier/addendum-sprime.md) and
[`dossier/diff-stats.txt`](dossier/diff-stats.txt).

## Deviations and process notes

1. Removed all seven actual public assertions, not only the four stated in the
   original objective.
2. Migrated `blocking_common`'s raw-audit boundary check to ordinary execution
   behavior.
3. Corrected allocation measurement to `Gc.counters` with promotion subtraction
   before collecting either side; the protocol was then frozen.
4. The original consumer map omitted the benchmark sink; Follow-up 1 corrects
   the line-level audit and dossier rather than hiding the miss.
5. Master advanced after the branch merge-base only in a scope-fenced state
   path. That path was not read or touched; semantic stats use the fixed
   merge-base.
6. The previously disclosed post-implementation reviewer grep incident in
   prohibited `docs/research/` occurred after the original experiment and did
   not report contents to this executor. No prohibited path was used in this
   follow-up.

## Final recommendation

**Promote S′.** It resolves S's inconsistent `collect_names` semantics, retains
R's two-field/no-names representation, and restores only T5's honest printable
blueprint operation. The boundary is proven by exact master parity, exhaustive
constructor/opacity coverage, law registration, and all four mandatory gates.

## Follow-up 2 pre-promotion fixes

1. The construction benchmark sink returned to R's safe `Effect.name`
   fingerprint. A filtered deep `Map` chain therefore receives a constant-depth
   leaf-label read instead of a quadratic-indentation `describe` traversal. The
   historical D7 consumer remains correct: `describe` was the sink at the
   BEFORE/S measurement point. Fingerprinting occurs after measured rows, so
   the recorded timing comparison is unchanged.
2. R166b now observes a side-effectful `Map` function as well as `Custom.eval`
   and `Bind.k`; all three flags remain false after `describe`. Registry source
   pointers were updated without changing the claim.

After both fixes, the native build/full-test/shipped trio, focused
`test/effect_introspection` suite, and mainline JS targets all passed. The
direct filtered quick benchmark also completed with `construction_sink=0`.
Exact records are the `*-final.status` files under
[`evidence/gates-sprime/`](evidence/gates-sprime/README.md).
