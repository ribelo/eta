# DiffableMap source options for Eta Signal keyed maps

Date: 2026-08-01
Repository revision: `dbc470105790bc50d7ed34c72f965431c4657d8a`
Branch: `docs/eta-crux-requirements` at `dbc47010`
Related ticket:
[Keyed assoc and stable child identity](../../../docs/wayfinder/eta-crux-first-principles/issues/04-keyed-assoc-contract.md)

[Diffable map product boundary](../../../docs/wayfinder/eta-signal-keyed-map/issues/03-diffable-map-product-boundary.md)
owns the final package and source choices. This report records evidence and
rejected alternatives.

## Question

Where can Eta obtain an immutable ordered DiffableMap that applications use
directly, with change-proportional reconciliation for maps that share
persistent ancestry?

This report compares primary-source candidates. It tests the hunch that Eta
must own its own implementation rather than depend on Jane Street or another
existing map package.

## Settled target

[Keyed assoc and stable child identity](../../../docs/wayfinder/eta-crux-first-principles/issues/04-keyed-assoc-contract.md)
accepts `Stdlib.Map.S` and an `O(n_old + n_new)` full merge plan. The product
decision reopens that collection contract. The research target is stronger:

- immutable ordered map used directly by applications
- change-proportional reconciliation when two map values share persistent
  ancestry
- not a full `Incr_map` operator set
- package boundary policy still applies: optional features publish
  `eta_<feature>` packages. Root `eta` stays free of optional stacks

Bonsai does not get keyed efficiency from plain Incremental. It depends on
`incr_map`, and `Incr_map` depends on Core/Base map symmetric diff. That is the
reference architecture, not an Eta package decision.

## Method

Primary sources only:

| Source | Identity | Role |
|---|---|---|
| [Keyed assoc and stable child identity](../../../docs/wayfinder/eta-crux-first-principles/issues/04-keyed-assoc-contract.md) | Eta revision above | Existing contract |
| [Reference semantics](../eta-crux/reference-semantics.md) | tracked research | Reference behavior |
| `Incr_map` | `21c6bc602c75d57242b4c3e945da597f82c6280f` | Keyed operators |
| Incremental tutorial | `6253411aa37e1ae758908bd285930659119eff2a` | Operator explanation |
| Base `Map` | `4e3b745fb95d66fa0e13601d7fa7aeaed7962043` | Map and diff code |
| Core `Map` | `core.v0.18~preview.130.91+190` | Complexity documentation |
| Stdlib `Map` | OCaml compiler source | Baseline API |
| Containers and Batteries | revisions in the evidence manifest | Standalone alternatives |
| ptmap and gmap | fixed opam versions in the evidence manifest | Specialized alternatives |

Secondary blogs and memory are not evidence.

See the [evidence manifest](EVIDENCE.md) for immutable revisions and URLs.

## What "DiffableMap" means here

There is no single published OCaml type named `DiffableMap` that matches the
settled Eta target. Nearby Jane Street names mean different things:

1. **Base/Core `Map.symmetric_diff` / `fold_symmetric_diff`**
   Tree-level structural diff of two maps of the same comparator. This is the
   operation that makes change-proportional keyed reconciliation possible.
2. **`ppx_diff` / `Diffable.Map_diff`**
   Serializeable change lists for map values, built on top of
   `Map.fold_symmetric_diff`. This is a value-diff codec layer, not the map
   container itself.
3. **`legacy_diffable`**
   A generic "diffable value" interface used by older Jane Street streaming
   code. It depends on Core and is not a standalone ordered map.
4. **`Incr_map`**
   Incremental operators over Core maps. It consumes map symmetric diff. It
   does not replace the map type.

Eta needs the first substrate. It combines an immutable ordered map,
ancestry-aware symmetric diff, and ordinary map construction operations.

---

## Candidate 1: OCaml `Stdlib.Map`

### API

Functor `Map.Make (Ord : OrderedType)` yields `Map.S`:

- `empty`, `add`, `remove`, `find` / `find_opt`, `mem`, `bindings`
- `merge`, `union`, `iter`, `fold`, `map`, `mapi`, `filter`, ...

There is no `symmetric_diff`, no `fold_symmetric_diff`, and no public tree
handle for an ancestry-aware diff outside the implementation.

Source: stdlib `map.mli`.

### Algorithm / complexity

`merge` walks both maps by key order. Keyed assoc and stable child identity records the practical
bound used by Eta Crux V1:

- reconciliation `O(n_old + n_new)`
- no change-proportional claim

Stdlib docs do not state a shared-structure skip for `merge`.

### Ancestry / structural sharing

Stdlib maps are persistent balanced trees and do share structure on updates.
That sharing is not exposed as a diff API. Two maps that share large subtrees
still require a full ordered merge to discover what changed.

### Dependencies / footprint / OCaml / license / maintenance

- part of the OCaml standard library
- no extra package
- available on every Eta compiler track
- license follows the OCaml distribution
- maintained with the compiler

### Fit modes

| Mode | Fit |
|---|---|
| Use existing type | Yes for ordinary maps. No for change-proportional reconciliation. |
| Wrap | Cannot wrap into change-proportional diff without internal tree access. |
| Copy / adapt | Would mean forking stdlib map internals into Eta. |
| Write Eta implementation | Same work as owning a map, but starting from stdlib shape. |

### Verdict

Correct public shape for key order and uniqueness. Insufficient as the
DiffableMap substrate under the settled target.

---

## Candidate 2: Jane Street Base `Map`

### API (exact surface that matters)

Base stores maps as first-class-comparator trees:

```ocaml
type (!'key, +!'value, !'cmp) t

val empty : ('a, 'cmp) Comparator.Module.t -> ('a, 'b, 'cmp) t

module Symmetric_diff_element : sig
  type ('k, 'v) t = 'k * [ `Left of 'v | `Right of 'v | `Unequal of 'v * 'v ]
end

val symmetric_diff
  :  ('k, 'v, 'cmp) t
  -> ('k, 'v, 'cmp) t
  -> data_equal:('v -> 'v -> bool)
  -> ('k, 'v) Symmetric_diff_element.t Sequence.t

val fold_symmetric_diff
  :  ('k, 'v, 'cmp) t
  -> ('k, 'v, 'cmp) t
  -> data_equal:('v -> 'v -> bool)
  -> init:'acc
  -> f:('acc -> ('k, 'v) Symmetric_diff_element.t -> 'acc)
  -> 'acc
```

Source: Base `map_intf.ml` (`Symmetric_diff_element`, `symmetric_diff`,
`fold_symmetric_diff`). Core re-exports the same map type as
`('key, 'value, 'cmp) Base.Map.t` and documents the same operations in
`core/map.mli`.

Applications construct maps with `Map.empty (module Key)` or key modules that
include `Comparable`. This is not `Stdlib.Map.S`.

### Algorithm / stated complexity

Implementation facts from Base `map.ml`:

- weight-balanced binary trees. Weight is `length t + 1`
- balancing parameters `(delta, gamma) = (5/2, 3/2)` (Hirai/Yamamoto style),
  documented in the `Tree0` header comment
- updates preserve physical equality of unchanged subtrees
  (`phys_equal` checks after recursive rebuilds)
- `Enum.drop_phys_equal_prefix` skips the largest physically equal shared
  prefix/subtrees before enumeration
- `fold_symmetric_diff` has a fast path that recurses on matching node
  structure and a slow enumeration fallback when roots diverge

Base interface docs state intent, not a closed-form bound:

> efficient in the case where `t1` and `t2` share a large amount of structure

Core docs add the concrete bound used by Jane Street consumers:

> In the case where `t2` (resp. `t1`) is obtained by applying k additions
> and/or removals to `t1` (resp. `t2`), this runs in `min(O(k log n), O(n))`,
> where `n` is `length t1 + length t2`.

Source: Core `map.mli` `symmetric_diff` comment. Base source implements the
sharing skip. Core documents the k-edit bound.

Important precondition, also from Base docs:

- `data_equal` must respect physical equality
  (`phys_equal x y` implies `data_equal x y`)
- otherwise the diff can omit unequal common keys after a shared-structure skip

### Ancestry / structural sharing behavior

This is true persistent ancestry, not hash-based approximation:

1. Map update reuses unchanged child pointers
2. Symmetric diff starts by dropping physically equal subtrees
3. Equal whole maps short-circuit (`phys_equal t t'`)
4. When roots no longer match after rebalance, the implementation falls back to
   slower enumeration of the remaining trees

The guarantee is therefore:

- change-proportional when maps share persistent ancestry from common updates
- not magic for independently rebuilt maps with identical contents

That matches the settled Eta target wording exactly.

### Dependencies / package footprint

Published Base v0.17.1 (`base.opam`):

- `ocaml >= 5.1.0`
- `ocaml_intrinsics_kernel`
- `sexplib0`
- `dune`, `dune-configurator`
- MIT license
- maintained by Jane Street (`x-maintenance-intent: (latest)` on current
  packages)

Current Base master / OxCaml Base add more Jane Street mode infrastructure:

- `basement`, `capsule0`, multiple `ppx_*` packages, `ppxlib_jane`
- OxCaml install pins `ppxlib = 0.33.0+ox`

Base is a full standard-library replacement, not a tiny map crate. Pulling Base
only for `Map` still imports the Base ecosystem and comparator style.

Core is much larger. Installed Core `META` requires Base plus bin_prot,
quickcheck, many ppx runtimes, portable, sexplib, and more. Core's opam file
lists dozens of Jane Street packages. Core is not a minimal map dependency.

### OCaml version support

- Base/Core current lines require OCaml `>= 5.1.0`
- available on the local OxCaml `5.2.0+ox` switch
- Jane Street packages track Jane Street's compiler and ppx stack closely.
  OxCaml already vendors a compatible set. A public dependency gives that stack
  to mainline OCaml consumers of Eta.

### License / maintenance

- Base package metadata says MIT. However, `src/map.ml` carries an INRIA
  copyright notice and says that the file uses Apache-2.0. A direct port must
  preserve that file-level notice and satisfy Apache-2.0.
- actively maintained by Jane Street
- API surface and dependency graph move with Jane Street releases

### Fit modes

| Mode | Fit |
|---|---|
| Use existing type | Technically yes: `Base.Map.t` already is an immutable ordered DiffableMap. Applications must adopt Base comparators. |
| Wrap | Possible as a private engine detail, but the public value still uses Base or a conversion boundary. Conversion destroys ancestry and the complexity claim. |
| Copy / adapt | Attractive algorithmically: copy the weight-balanced tree and `fold_symmetric_diff`. Requires the INRIA notice, Apache-2.0 compliance, exact source provenance, and long-term ownership. |
| Write Eta implementation | Reimplements the same idea under Eta ownership and `Stdlib`-friendly or Eta-native key modules. |

### Verdict

Best existing implementation of the required algorithm. Heavy package and API
tax if applications must use it directly.

---

## Candidate 3: `Incr_map`

### What it is

Package synopsis from `Incr_map` package metadata at
`21c6bc602c75d57242b4c3e945da597f82c6280f`:

> Helpers for incremental operations on map like data structures. This
> leverages new functionality in Incremental along with the ability to
> efficiently diff map data structures using `Map.symmetric_diff`.

License: MIT. OCaml: `>= 5.1.0`. Maintenance: Jane Street
`x-maintenance-intent: (latest)`.

### Dependencies / footprint

Direct depends at the reviewed commit:

- `abstract_algebra`
- `bignum`
- `core`
- `incremental`
- `legacy_diffable`
- `ppx_diff`
- `ppx_jane`
- `ppx_pattern_bind`
- `ppx_stable_witness`
- `streamable`
- `dune >= 3.17.0`

This is an Incremental companion library, not a map container.

### Exact API role for keyed assoc

The operator closest to Bonsai/Eta keyed children is `mapi'`:

```ocaml
val mapi'
  :  ?instrumentation:Instrumentation.t
  -> ?cutoff:'v1 Incr.Cutoff.t
  -> ?data_equal:('v1 -> 'v1 -> bool)
  -> ('k, 'v1, 'cmp) Map.t Incr.t
  -> f:(key:'k -> data:'v1 Incr.t -> 'v2 Incr.t)
  -> ('k, 'v2, 'cmp) Map.t Incr.t
```

Implementation in `incr_map.ml` `generic_mapi'`:

1. Keep previous Core map and previous per-key nodes
2. On input change, call `Map.fold_symmetric_diff ~data_equal`
3. For `` `Unequal ``, mark the per-key data node stale
4. For `` `Left ``, remove dependency, invalidate node, drop output entry
5. For `` `Right ``, create a new expert node and run `f`

Instrumentation docs state that the bulk work is usually
`Map.fold_symmetric_diff`.

Incremental tutorial `part3-map.mdx` is explicit:

- ordinary `Incr.map` over a whole `Map.t` recomputes from scratch
- efficient keyed work needs map diffability and `Incr_map`

### Ancestry behavior

`Incr_map` does not implement tree diff itself. It inherits Base/Core map
ancestry behavior through `Map.fold_symmetric_diff`.

### Fit modes

| Mode | Fit |
|---|---|
| Use existing type | No. It is not a DiffableMap type. |
| Wrap | Wrong layer. It couples to Incremental expert nodes, Core maps, and Jane Street ppx. |
| Copy / adapt | Useful reference for the *engine operator* over a diffable map, not for the map container. Keyed assoc and stable child identity used `mapi'` this way. |
| Write Eta implementation | Eta Signal needs its own keyed node. Reusing `Incr_map` imports Incremental. |

### Verdict

Primary reference for change-proportional keyed operators. Not a candidate for
the application-facing DiffableMap type. This dependency violates the direct
application-map target and Eta package boundaries.

---

## Candidate 4: Jane Street `Diffable.Map_diff` / `ppx_diff`

### API

```ocaml
module Change : sig
  type ('k, 'v, 'v_diff) t =
    | Remove of 'k
    | Add of 'k * 'v
    | Diff of 'k * 'v_diff
end

type ('k, 'v, 'v_diff) t = ('k, 'v, 'v_diff) Change.t list

val get
  :  (from:'v -> to_:'v -> 'v_diff Optional_diff.t)
  -> from:('k, 'v, 'cmp) Map.t
  -> to_:('k, 'v, 'cmp) Map.t
  -> ('k, 'v, 'v_diff) t Optional_diff.t
```

Source: `ppx_diff/diffable/map_diff.mli`.

### Implementation

`Map_diff.get` calls `Map.fold_symmetric_diff` with `data_equal:phys_equal`,
then builds remove/add/diff lists. Source: `map_diff.ml`.

### Fit

This is a diff encoding on top of Base maps. It presupposes Base/Core maps and
adds bin_io / stable_witness / ppx machinery. It does not give Eta a map type
applications can own. Useful only as evidence that Jane Street's "diffable map"
story bottoms out in `Map.fold_symmetric_diff`.

---

## Candidate 5: Standalone OCaml map libraries

### containers `CCMap`

- package: modular stdlib extension, BSD-2-Clause
- opam `containers.3.15`: `ocaml >= 4.08 & < 5.4`, small deps (`either`)
- `CCMap` extends `Map.S` with helpers such as `merge_safe`, iterators, printers
- source interface includes no `symmetric_diff` and no ancestry-aware
  complexity claim
- still built on ordinary stdlib maps / functor maps

Fit: convenience wrapper. Not DiffableMap.

### batteries `BatMap`

- community stdlib extension, LGPL-2.1-or-later WITH OCaml linking exception
- opam `batteries.3.9.0`: `ocaml >= 4.05 & < 5.4`
- `BatMap` has `diff`, but the docs define key-set subtraction:
  remove keys found in `m2` from `m1`
- that is not symmetric structural diff and does not claim shared-ancestry
  change proportionality

Fit: not the required algorithm.

### ptmap

- Patricia trees over `int` keys, LGPL-2.1-only
- inspired by Okasaki and Gill mergeable integer maps
- opam `ptmap.2.0.5`: tiny dependency set
- interface is a subset of `Map.S with type key = int`
- docs explicitly say key order is not efficiently maintained:
  `iter` / `fold` are not key-ordered. `bindings` is not sorted
- has `merge` / `union`, no symmetric ancestry diff API for arbitrary ordered
  keys

Fit: wrong key domain and wrong ordering contract for Eta assoc output order.

### gmap

- heterogenous GADT-keyed maps, ISC
- implemented on top of stdlib `Map`
- solves typed packing, not structural diff

Fit: different problem.

### Search result for a standalone DiffableMap

Across opam package metadata and the primary interfaces above, no maintained
standalone OCaml package presents:

- arbitrary totally ordered keys
- immutable persistent ordered map as the application value type
- public symmetric structural diff with shared-ancestry complexity
- small non-Jane-Street dependency footprint

The only complete implementation found is Jane Street Base/Core `Map`.

---

## Comparison matrix

| Candidate | Ordered immutable map apps can hold | Ancestry-aware symmetric diff | Stated change-proportional bound | Dep footprint | License | Use as Eta public map type? |
|---|---|---|---|---|---|---|
| `Stdlib.Map` | Yes | No | No (`O(n_old+n_new)` merge only) | Zero | OCaml | Yes for V1 linear recon. No for settled target |
| Base `Map` | Yes, with comparators | Yes | Core docs: `min(O(k log n), O(n))` under k edits from shared ancestry | Large stdlib replacement | MIT package. `map.ml` says Apache-2.0 | Possible, high ecosystem cost |
| Core `Map` | Same type as Base | Yes | Same as Base/Core docs | Much larger than Base | MIT | No reason over Base |
| `Incr_map` | No, uses Core maps | Via Core | Via Core | Core + Incremental + ppx stack | MIT | No |
| `Diffable.Map_diff` | No | Via Core/Base | Via Core/Base | ppx_diff stack | MIT | No |
| containers / batteries | Yes-ish | No | No | Medium | BSD / LGPL | No for settled target |
| ptmap | int keys only, weak order | No public API | Mergeable ints, not assoc order | Small | LGPL-2.1 | No |
| gmap | Yes, stdlib-backed | No | No | Small | ISC | No |
| Eta-owned map | Yes, by design | Yes, if implemented | Can state and test the claim | Controlled by Eta | Eta-chosen | Yes |

---

## Decision axes for Eta

### 1. Use an existing type

Only Base/Core `Map.t` currently satisfies the settled DiffableMap algorithm.
That forces:

- first-class comparators instead of plain `Map.S`
- Base (minimum) or Core (if any Core-only helper is used) in the public or
  package dependency graph
- application code and examples to construct Jane Street maps
- likely friction with Eta's "install only what you use" and with non-Jane
  Street consumers

Keyed assoc and stable child identity selected `Stdlib.Map.S` for linear
reconciliation. That choice is weaker than this research target.

### 2. Wrap an existing type

Wrapping Base maps privately while exposing `Stdlib.Map` fails the ancestry
requirement. Conversion rebuilds the tree and removes shared physical
structure.

Wrapping Base maps and also exposing Base maps publicly is not wrapping. It is
adopting Base as the application map type.

### 3. Copy or adapt code

Porting Base `fold_symmetric_diff` and the minimum weight-balanced tree is
technically credible:

- algorithm is localized in `map.ml` tree and enum code
- the permissive Apache-2.0 file license permits a direct port when Eta keeps
  the required notice and license terms
- Eta can publish a narrow map module without Incremental, Core, or ppx

Costs:

- long-term ownership of a non-trivial balanced-tree implementation
- need to re-home comparator/key-module design into Eta style
- must preserve and test the physical-sharing complexity claim
- must track the exact Base revision and the file-level INRIA and Apache-2.0
  provenance

This is closer to "Eta owns a map" than to "Eta depends on Base".

### 4. Write Eta's implementation

The product boundary fixes package placement. Implementation still chooses:

- functor style (`Map.S`) versus first-class comparator modules
- exact diff element type
- OxCaml mode annotations later, without importing Jane Street modes wholesale

This is the only path that simultaneously:

- gives applications a map type Eta controls
- supports change-proportional reconciliation
- avoids Core/Incremental/`Incr_map` package boundaries
- keeps the root `eta` package free of optional Jane Street stacks

---

## Test of the user's hunch

Hunch: Eta will need its own implementation.

Evidence:

1. The required algorithm exists and is production-proven in Base/Core Map.
2. That algorithm is not available from `Stdlib.Map` or from the major
   standalone map helpers reviewed above.
3. `Incr_map` is the wrong layer: operators over someone else's map, plus a
   huge Incremental/Core dependency cone.
4. Using Base/Core maps directly satisfies the algorithm but makes Jane
   Street Map the application collection type and imports a large ecosystem.
5. Converting to/from stdlib maps destroys the ancestry that the complexity
   claim needs.
6. Eta package policy prefers feature packages with explicit deps, and prefers
   not to force optional ecosystem stacks on ordinary programs.

Conclusion: the hunch is **confirmed for an Eta-owned DiffableMap type**, with
one important nuance:

- Eta does **not** need to invent a new algorithm.
- Eta **does** need to own the map implementation or intentionally adopt Base
  Map as the public map type.
- Under Eta's package and API constraints, owning the implementation is the
  coherent choice.
- Base/Core remain the primary reference implementation and test oracle for
  symmetric diff behavior and complexity.
- `Incr_map.mapi'` remains the primary reference for the keyed engine operator
  once a DiffableMap exists.

Adopting Base Map publicly makes the dependency boundary the primary decision.
No current Eta package exposes Base or Core as a public dependency.

---

## Recommendation

### Primary recommendation

**Implement an Eta-owned immutable ordered DiffableMap** and publish it as the
application-facing collection type for keyed signal work, almost certainly
under or beneath `eta_signal_map`.

Minimum map contract to extract from Base/Core:

```ocaml
type ('k, 'v) symmetric_diff_element =
  'k * [ `Left of 'v | `Right of 'v | `Unequal of 'v * 'v ]

val fold_symmetric_diff
  :  data_equal:('v -> 'v -> bool)
  -> 'v t
  -> 'v t
  -> init:'acc
  -> f:('acc -> ('k, 'v) symmetric_diff_element -> 'acc)
  -> 'acc
```

plus ordinary ordered-map operations applications need
(`empty`, `add`/`set`, `remove`, `find`, `bindings` / ordered iteration,
`length` in O(1) or O(log n) with documented cost).

Normative complexity claim to carry with tests:

- if `t2` is obtained from `t1` by `k` single-entry insertions, deletions, or
  replacements that preserve persistent ancestry, reconciliation is
  `min(O(k log n), O(n))`
- independently rebuilt equal contents can cost `O(n)`
- `data_equal` must respect physical equality

### Secondary recommendation

Keep Base/Core Map and `Incr_map` as **reference oracles**, not runtime
dependencies:

- Base `map.ml` for tree + `fold_symmetric_diff`
- Core docs for the published complexity sentence
- `Incr_map.mapi'` for per-key node lifecycle over a diff stream
- the structural laws in Keyed assoc and stable child identity remain above the map substrate

### Explicitly reject for the DiffableMap type

- `Incr_map` as the map package
- `Diffable.Map_diff` as the map package
- containers / batteries / ptmap / gmap as the substrate for the settled target
- a public stdlib map plus private Base conversion wrapper that claims
  change-proportional reconciliation

### Package boundary sketch (non-binding)

| Layer | Owns |
|---|---|
| Eta DiffableMap package or `eta_signal_map` substrate | map type, constructors, `fold_symmetric_diff`, laws/benches |
| `eta_signal` private engine | keyed node that consumes the diff stream and manages scopes |
| Eta Crux `Assoc` | application description over the public map type |

Do not put Base/Core/Incremental into root `eta`.

### Implementation strategy order

1. Fix the public DiffableMap signature and key-module discipline.
2. Write a clean-room weight-balanced map and ancestry-aware
   `fold_symmetric_diff` from the cited algorithms. Use Base as a test oracle.
3. Benchmark k-edit reconciliation versus full merge to make the claim
   executable.
4. Only then rewire keyed signal operators from `M.merge` to
   `fold_symmetric_diff`.

### What this does not decide

The public map prototype decides a functor API or a first-class comparator API.
The product boundary ticket owns package placement and source policy.

The source-options question is settled enough:

> No small third-party DiffableMap exists for Eta to take off the shelf.
> Base/Core Map is the only complete existing implementation.
> Under Eta constraints, Eta owns the map type and treats Jane Street as the
> behavior reference.

---

## Source index

The [evidence manifest](EVIDENCE.md) gives each immutable revision and URL.
The source review used these symbols and files:

- Base `Tree0.fold_symmetric_diff` and `Enum.drop_phys_equal_prefix`
- Base `Map_intf` symmetric-diff types and equality precondition
- Base `test_map` reconstruction and comparison-count cases
- `Incr_map.generic_mapi'` and its `fold_symmetric_diff` calls
- Incremental `part3-map.mdx`
- Core `Map` complexity documentation from the recorded package version
- the public map interfaces for Stdlib, Containers, Batteries, ptmap, and gmap
- [Reference semantics](../eta-crux/reference-semantics.md)

## Open evidence gaps

1. This report did not run the Base `fold_symmetric_diff` benchmark locally.
   The complexity evidence comes from Core documentation and Base source.
2. GitHub code search returned an authentication error. The standalone-package
   result uses opam metadata and reviewed public interfaces.
3. The public map prototype decides a functor API or a Base-style comparator
   API.
