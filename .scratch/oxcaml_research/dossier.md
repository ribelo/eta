# OxCaml Capability Dossier

**Version surveyed:** 5.2.0+ox (production switch), with upstream 5.4 merge in progress as of April 2026.  
**Date of dossier:** 2026-05-21.  
**Scope:** Features relevant to an Effet (OCaml 5 effect-system library) migration.

---

## 1. Mode system inventory

### 1.1 Locality (scope / stack allocation)

| Aspect | Detail |
|--------|--------|
| Syntax | `local`, `global` on values; `stack_` on allocations; `exclave_` for local-returning functions; `local_` for let-bindings and parameters; `global_` on record fields. |
| Axis type | Future mode (tracks whether a value may escape its region). |
| Subtyping | `local` < `global`. Values may move freely to greater modes. `global` may be weakened to `local`. |
| Mode-crossing | Types that never heap-allocate (e.g. `int`) cross locality: they may be used as `global` even when marked `local`. |
| Legacy default | `global`. |
| Stability | **Stable in 5.2.0+ox.** Documented as a core feature on oxcaml.org since at least June 2025. |

Sources: [oxcaml.org Modes Intro](https://oxcaml.org/documentation/modes/intro/) (2025-06-13); [oxcaml.org Stack Allocation Reference](https://oxcaml.org/documentation/stack-allocation/reference/) (2025-06-13); [oxcaml.org Modes Syntax](https://oxcaml.org/documentation/modes/syntax/) (2025-06-13).

### 1.2 Portability (cross-domain sharing)

| Aspect | Detail |
|--------|--------|
| Syntax | `portable`, `nonportable`. |
| Axis type | Future mode (tracks whether a value may be shared with another thread). |
| Subtyping | `portable` < `nonportable`. `portable` functions may not close over unprotected mutable state. |
| Mode-crossing | Types that do not contain functions cross portability. `Capsule.Data.t`, `Portable.Atomic.t`, and `exn` are declared to cross portability. |
| Legacy default | `nonportable`. |
| Stability | **Stable in 5.2.0+ox.** Core to the data-race-freedom guarantee. |

Sources: [oxcaml.org Modes Intro](https://oxcaml.org/documentation/modes/intro/) (2025-06-13); [oxcaml.org Parallelism Intro](https://oxcaml.org/documentation/parallelism/01-intro/) (2025-06-13); KC Sivaramakrishnan, "Data race freedom in OxCaml" (2026-05-07) [kcsrk.info](https://kcsrk.info/ocaml/oxcaml/x-ocaml/blogging/2026/05/07/data-race-freedom-in-oxcaml/).

### 1.3 Contention (concurrent access history)

| Aspect | Detail |
|--------|--------|
| Syntax | `uncontended`, `shared`, `contended`. |
| Axis type | Past mode (tracks whether a value has been shared between threads). |
| Subtyping | `uncontended` < `shared` < `contended`. A `contended` value may not have its unprotected mutable portions read or written. `shared` values may be read but not written. |
| Mode-crossing | Deeply immutable types cross contention. `int`, `string`, `Capsule.Data.t`, `Portable.Atomic.t` cross contention. |
| Legacy default | `uncontended`. |
| Stability | **Stable in 5.2.0+ox.** Core to data-race freedom. |

Sources: [oxcaml.org Modes Intro](https://oxcaml.org/documentation/modes/intro/) (2025-06-13); [oxcaml.org Parallelism Intro](https://oxcaml.org/documentation/parallelism/01-intro/) (2025-06-13).

### 1.4 Linearity (usage count)

| Aspect | Detail |
|--------|--------|
| Syntax | `many`, `once`. |
| Axis type | Future mode (tracks how many times a value may be used). |
| Subtyping | `once` < `many`. `once` values may be used at most once. |
| Mode-crossing | Types that do not allocate or contain functions cross linearity. |
| Legacy default | `many`. |
| Stability | **Stable in 5.2.0+ox.** Used by capsule keys (uniqueness + linearity). |

Sources: [oxcaml.org Modes Syntax](https://oxcaml.org/documentation/modes/syntax/) (2025-06-13); [oxcaml.org Uniqueness Reference](https://oxcaml.org/documentation/uniqueness/reference/) (2025-06-13).

### 1.5 Uniqueness (aliasing)

| Aspect | Detail |
|--------|--------|
| Syntax | `unique`, `aliased`. |
| Axis type | Past mode (tracks whether at most one reference exists). |
| Subtyping | `unique` < `aliased`. `unique` enables in-place mutation via `overwrite_` (see ownership blog). |
| Mode-crossing | Same as linearity: immediate/non-allocating types cross. |
| Legacy default | `aliased`. |
| Stability | **Stable in 5.2.0+ox.** |

Sources: [oxcaml.org Uniqueness Reference](https://oxcaml.org/documentation/uniqueness/reference/) (2025-06-13); Max Slater, "Oxidizing OCaml: Rust-Style Ownership", Jane Street Blog (2024, possibly stale for syntax specifics); KC Sivaramakrishnan, "Linearity and uniqueness" (2025-06-04) [kcsrk.info](https://kcsrk.info/ocaml/modes/oxcaml/2025/06/04/linearity_and_uniqueness/).

### 1.6 Statefulness

| Aspect | Detail |
|--------|--------|
| Syntax | `stateless`, `observing`, `stateful`. |
| Axis type | Future mode. |
| Subtyping | `stateless` < `observing` < `stateful`. |
| Legacy default | `stateful`. |
| Stability | **Listed in syntax reference; largely undocumented in tutorials.** Treat as experimental / proposed. |

Source: [oxcaml.org Modes Syntax](https://oxcaml.org/documentation/modes/syntax/) (2025-06-13).

### 1.7 Visibility

| Aspect | Detail |
|--------|--------|
| Syntax | `read_write`, `read`, `immutable`. |
| Axis type | Future mode. |
| Subtyping | `immutable` < `read` < `read_write`. |
| Legacy default | `read_write`. |
| Stability | **Listed in syntax reference; minimal tutorial coverage.** Treat as experimental. |

Source: [oxcaml.org Modes Syntax](https://oxcaml.org/documentation/modes/syntax/) (2025-06-13).

### 1.8 Forkable

| Aspect | Detail |
|--------|--------|
| Syntax | `forkable`, `unforkable`. |
| Axis type | Future mode (tracks whether a function may access shared values in its parent stack). |
| Subtyping | `forkable` < `unforkable`. |
| Legacy default | Depends on locality (documented as having different defaults based on locality). |
| Stability | **Stable enough to appear in `Parallel.fork_join2` signatures, but less documented than portability/contention.** |

Sources: [oxcaml.org Modes Intro](https://oxcaml.org/documentation/modes/intro/) (2025-06-13); [janestreet/parallel README](https://github.com/janestreet/parallel/blob/oxcaml/README.md) (2025-05-27).

### 1.9 Yield

| Aspect | Detail |
|--------|--------|
| Syntax | `unyielding`, `yielding`. |
| Axis type | Future mode. |
| Legacy default | `unyielding`. |
| Stability | **Listed in syntax reference only.** Unknown maturity. |

Source: [oxcaml.org Modes Syntax](https://oxcaml.org/documentation/modes/syntax/) (2025-06-13).

### 1.10 Modality syntax summary

Modalities (relationship between container and element) are written with `@@`:

```ocaml
type r = { x : string @@ portable }
include S @@ portable
```

On a future axis, a modality imposes an upper bound (lowering the mode of the field). On a past axis, it imposes a lower bound (raising the mode). Identity modalities are `local unique once nonportable uncontended unforkable yielding stateless immutable`.

Source: [oxcaml.org Modes Syntax](https://oxcaml.org/documentation/modes/syntax/) (2025-06-13).

### 1.11 Stability summary

| Axis | Maturity |
|------|----------|
| locality | Stable |
| portability | Stable |
| contention | Stable |
| linearity | Stable |
| uniqueness | Stable |
| forkable | Semi-stable (used in APIs) |
| statefulness | Experimental / undocumented |
| visibility | Experimental / undocumented |
| yield | Unknown / syntax-only |

---

## 2. Kinds and layouts inventory

### 2.1 Core kind syntax

A kind has the form `<layout> mod <bounds>`, where bounds include modal bounds, with-bounds, and non-modal bounds.

Source: [oxcaml.org Kinds Intro](https://oxcaml.org/documentation/kinds/intro/) (2025-06-13).

### 2.2 Layouts

| Layout | Status | Description |
|--------|--------|-------------|
| `value` | Stable | Normal OCaml heap values. Default for unannotated type variables. |
| `value_or_null` | Behind `-extension-universe alpha` | Superlayout of `value` including null pointers. |
| `immediate` | Stable | No pointer indirection (e.g. `int`). Sub-layout of `value`. |
| `immediate64` | Stable | `immediate` on 64-bit, `value` on 32-bit. |
| `float64` | Stable | Unboxed float (`float#`). |
| `float32` | Stable | Unboxed 32-bit float (`float32#`). |
| `bits32` | Stable | Unboxed int32 (`int32#`). |
| `bits64` | Stable | Unboxed int64 (`int64#`). |
| `word` | Stable | Unboxed nativeint (`nativeint#`). |
| `vec128` | Stable (x86_64 only; ARM unsupported) | 128-bit SIMD vectors. |
| `void` | Unknown / not in public docs | Not documented on oxcaml.org as of 2025-06-13. |
| `any` | Stable | Super-layout of all layouts. |
| `any_non_null` | Stable | Sub-layout of `any` forbidding null. |
| `l1 & ... & lk` | Stable | Unboxed product layout. |

**`or_null` / non-allocating option:** `t or_null` uses the `value_or_null` layout to represent `Some x` / `Null` without allocation. It requires `-extension-universe alpha` to expose the layout in user annotations. By default `value_or_null` is displayed as `value`. The constructors are `This` and `Null`.

**`[@unboxed]` attribute:** Records and variants declared with `[@@unboxed]` have the same kind as their single field. This is distinct from unboxed product tuples (`#(ty1 * ty2)`).

**`with` bounds syntax:** Container kinds use `with` to propagate element bounds. Example:
```ocaml
type 'a list : immutable_data with 'a
type ('a : any) array : mutable_data with 'a
```

Important caveat from the official docs: "Unboxed types are still in active development, with new features being added frequently."

Sources: [oxcaml.org Unboxed Types Intro](https://oxcaml.org/documentation/unboxed-types/01-intro/) (2025-06-13); [oxcaml.org Kinds Intro](https://oxcaml.org/documentation/kinds/intro/) (2025-06-13); [oxcaml.org Get OxCaml](https://oxcaml.org/get-oxcaml/) (2025-06-13) (notes SIMD not on ARM).

### 2.3 Kind abbreviations

| Abbreviation | Expansion |
|--------------|-----------|
| `immediate` | `value mod everything non_null non_float` |
| `immutable_data` | `value mod global aliased many contended portable forkable unyielding immutable` (plus with-bounds) |
| `mutable_data` | Similar to `immutable_data` but without `immutable` bound |
| `everything` | `global aliased many contended portable forkable unyielding immutable stateless external_` |

Source: [oxcaml.org Kinds Syntax](https://oxcaml.org/documentation/kinds/syntax/) (2025-06-13).

### 2.4 Unboxed records, variants, and tuples

- **Unboxed records:** Declared with `[@@unboxed]`. Have the same kind as their single field. An unboxed record with multiple fields (via implicit declaration) has kind `lay_1 & ... & lay_n mod everything`.
- **Unboxed variants:** `[@@unboxed]` on a variant type.
- **Unboxed tuples:** Syntax `#(ty1 * ty2)`. Layout is the product of constituent layouts. Passed in multiple registers.

Source: [oxcaml.org Kinds Types](https://oxcaml.org/documentation/kinds/types/) (2025-06-13); [oxcaml.org Unboxed Types Intro](https://oxcaml.org/documentation/unboxed-types/01-intro/) (2025-06-13).

### 2.5 Mixed blocks and atomic fields

**Mixed blocks:** Not explicitly documented on oxcaml.org as a standalone stable feature as of June 2025. The unboxed-types page is the canonical reference for memory layout control; mixed blocks may be subsumed by or related to the unboxed-types / layout work.

**Mixed blocks:** The `Mixed blocks: Storing More Fields Flat` talk was presented at the OCaml Workshop 2024 by Nick Roberts and is referenced on the OxCaml documentation bibliography page. As of the 5.2.0+ox production switch, mixed blocks are not documented as a standalone stable feature on oxcaml.org; they may be subsumed by the ongoing unboxed-types / layout work.

**Atomic fields:** `[@atomic]` on record fields is an **upstream OCaml 5.4 feature** (PR [#13404](https://github.com/ocaml/ocaml/pull/13404), merged 2024-08-27). OxCaml has `Atomic.Contended` and `Portable.Atomic.t` as part of its portable library. It is unknown whether OxCaml exposes the upstream `[@atomic]` attribute or has its own syntax. The `@@ atomic` modality syntax is not documented in the public mode syntax reference as of June 2025.

Sources: [ocaml/ocaml PR #13404](https://github.com/ocaml/ocaml/pull/13404) (2024-08-27); KC Sivaramakrishnan, "Data race freedom in OxCaml" (2026-05-07) (mentions `Portable.Atomic`); [oxcaml.org Parallelism Intro](https://oxcaml.org/documentation/parallelism/01-intro/) (2025-06-13).

### 2.6 Recursive-GADT kind inference

The official docs state explicitly:

> "layout inference is incomplete in certain complicated scenarios with mutually recursive type definitions. If layout inference does not work, you will get an error asking you to write a layout annotation; we will never infer an incorrect layout."

This means recursive GADT-heavy code (like Effet's `Effect.t`) may require manual kind annotations on type parameters or the type itself, e.g.:

```ocaml
type ('a : value mod portable) eff : value mod portable
```

There is no mention of a specific "I gave up trying to find the simplest kind" message being fixed in newer versions; the docs describe the behavior as expected and require user annotations.

Source: [oxcaml.org Unboxed Types Intro](https://oxcaml.org/documentation/unboxed-types/01-intro/) (2025-06-13).

---

## 3. Capsules and runtime concurrency

### 3.1 Capsule API (expert)

The "expert" API lives in `Capsule_expert` (or `Capsule` in older versions). Core types:

| Type | Role |
|------|------|
| `('a, 'k) Capsule.Data.t` | Pointer to mutable state branded by capsule `'k`. Crosses portability and contention. |
| `'k Capsule.Key.t` | Statically unique key for capsule `'k`. Protected by uniqueness mode. |
| `'k Capsule.Password.t` | Permission to make `'k` the current capsule. Always `local`. Crosses contention but not locality. |
| `'k Capsule.Access.t` | Evidence that `'k` is the current capsule. Does **not** cross contention. |

Creating a capsule:
```ocaml
let (P key) = Capsule.create () in
let data = Capsule.Data.create (fun () -> ref 0) in
let mutex = Capsule.Mutex.create key in
```

Passwords are obtained via `Capsule.Key.with_password` (unique key) or `Capsule.Mutex.with_lock` (mutex). The callback receives `password @ local`.

Sources: [oxcaml.org Parallelism Capsules](https://oxcaml.org/documentation/parallelism/02-capsules/) (2025-06-13); KC Sivaramakrishnan, "Capsules: compile-time lock discipline in OxCaml" (2026-05-08) [kcsrk.info](https://kcsrk.info/ocaml/oxcaml/modes/blogging/2026/05/08/capsules-in-oxcaml/); [oxcaml.org Parallelism Tutorial Part 2](https://oxcaml.org/documentation/tutorials/02-intro-to-parallelism-part-2/) (2025-06-13).

### 3.2 Portable.Atomic and Atomic.Contended

- `Portable.Atomic.t` is an atomic reference that crosses portability and contention. It is the OxCaml replacement for raw `ref` in parallel contexts.
- `Atomic.Contended` is mentioned in the modes reference as part of the atomic-fields discussion; the exact API shape is not fully documented on oxcaml.org.

Sources: KC Sivaramakrishnan, "Data race freedom in OxCaml" (2026-05-07); [oxcaml.org Modes Reference](https://oxcaml.org/documentation/modes/reference/) (2025-06-13).

### 3.3 Parallel package

`janestreet/parallel` provides:

- `Parallel.fork_join2 : t @ local -> (t @ local -> 'a) @ forkable local once shareable -> (t @ local -> 'b) @ once shareable -> #('a * 'b)`
- `Parallel_scheduler` (work-stealing domain pool)
- `Parallel.Arrays.Array` and `Slice` for parallel mutable arrays
- `parallel_map`, `parallel_sequence`, `parallel_reduce` (implied by tutorial, exact module names not verified)

Functions passed to `fork_join` must be `portable` and `shareable`.

Source: [janestreet/parallel README](https://github.com/janestreet/parallel/blob/oxcaml/README.md) (2025-05-27); [oxcaml.org Parallelism Tutorial Part 1](https://oxcaml.org/documentation/tutorials/01-intro-to-parallelism-part-1/) (2025-06-13).

### 3.4 Await package

`janestreet/await` provides **low-level support for suspending and resuming fibers** with cancelation propagation. It is Jane Street's OxCaml-native concurrency primitive, distinct from Eio.

Key signature pattern:
```ocaml
val with_access
  : Await.t @ local
  -> 'k Await.Mutex.t @ local
  -> f:('k Capsule.Access.t @ local -> 'a) @ local once
  -> 'a
```

Source: [janestreet/await README](https://github.com/janestreet/await/blob/oxcaml/README.md) (2025-05-27).

### 3.5 portable_lockfree_htbl and portable_ws_deque

**Unknown.** No public repository named `janestreet/portable_lockfree_htbl` or `janestreet/portable_ws_deque` was found via search. The `janestreet/portable` repository (2025-05-27) is described only as "Library for parallel programming in OCaml and OxCaml" with no README content visible in search results. Saturn/lockfree (`ocaml-multicore/saturn`) is the upstream lockfree library but its compatibility with OxCaml's mode system is unverified.

### 3.6 Interaction with OCaml 5 effect handlers

Jane Street has a separate library, `janestreet/handled_effect`, that uses the `local` mode to encode **effect safety**:

> "Each effect handler can be represented as a `local` argument, which is needed to perform its operations. Functions accepting `local` functions are then effect-polymorphic."

Example from the repo:
```ocaml
val divide : ExnHandler.t @ local -> int -> int -> int
val catch : f:(ExnHandler.t @ local -> 'a) @ local -> 'a option
```

This is an **alternative to Eio's effect-handler model**. It does not use OCaml 5's bare `effect`/`perform` directly; instead it uses `local` capabilities to ensure every performed effect has a handler on the stack.

Source: [janestreet/handled_effect README](https://github.com/janestreet/handled_effect/blob/oxcaml/README.md) (2025-04-27).

### 3.7 Interaction with Eio

**No OxCaml-specific Eio shims were found.** Eio (`ocaml-multicore/eio`) is developed independently and does not carry OxCaml mode annotations (`local_`, `portable`, etc.) in its public API as of its latest releases. Effet currently uses Eio as its runtime backend. Migrating to OxCaml's full mode system while keeping Eio may require:

1. Wrapping Eio primitives in mode-annotated interfaces, or
2. Migrating from Eio to Jane Street's `Await` + `handled_effect` stack.

The `await` package is explicitly described as fiber suspension/resumption with cancelation, which overlaps with Eio's fiber model.

Sources: [janestreet/handled_effect README](https://github.com/janestreet/handled_effect/blob/oxcaml/README.md) (2025-04-27); [janestreet/await README](https://github.com/janestreet/await/blob/oxcaml/README.md) (2025-05-27); [ocaml-multicore/eio](https://github.com/ocaml-multicore/eio) (no OxCaml annotations visible in search).

---

## 4. Recent (last ~6 months) and upcoming features

### 4.1 What landed recently

| Feature | Status | Evidence |
|---------|--------|----------|
| Upstream 5.4 merge | In progress / largely complete as of April 2026 | [oxcaml/oxcaml Wiki "Notes on merging 5.4"](https://github.com/oxcaml/oxcaml/wiki/Notes-on-merging-5.4) (2026-04-02) |
| Merlin upgrade to 5.4 | Merged April 2026 | [oxcaml/merlin PR #227](https://github.com/oxcaml/merlin/pull/227) (2026-04-01) |
| Unboxed types improvements | Active | [oxcaml/oxcaml PR #4826](https://github.com/oxcaml/oxcaml/pull/4826) (2025-10-03) |
| Zero-alloc analysis improvements | Planned / in progress | [oxcaml/oxcaml Issue #5278](https://github.com/oxcaml/oxcaml/issues/5278) (2026-01-20) |
| odoc support for modes/kinds | In progress (April 2026) | [ocaml/odoc PR #1410](https://github.com/ocaml/odoc/pull/1410) (2026-04-14); [ocaml/odoc Issue #1416](https://github.com/ocaml/odoc/issues/1416) (2026-04-14) |
| Dune parameterized libraries | Experimental; Dune 3.20+ | [Dune docs](https://dune.readthedocs.io/en/stable/tutorials/oxcaml-parameterized-library/index.html) (2025-2026) |
| `or_null` / non-allocating option | Alpha / behind `-extension-universe alpha` | [oxcaml.org Unboxed Types Or-Null](https://oxcaml.org/documentation/unboxed-types/02-or-null/) (2025-06-13) |

### 4.2 Experimental / behind extension flags

- `-extension-universe beta` enables unstable extensions like `comprehensions`.
- `-extension-universe alpha` is required for `value_or_null` layout exposure.
- SIMD compiler extension is **not supported on ARM**.
- `statefulness`, `visibility`, and `yield` modes are syntactically valid but largely undocumented.

Source: [oxcaml.org Get OxCaml](https://oxcaml.org/get-oxcaml/) (2025-06-13); [oxcaml.org Modes Syntax](https://oxcaml.org/documentation/modes/syntax/) (2025-06-13).

### 4.3 Upstream-merge status

OxCaml is Jane Street's production compiler and a laboratory for upstream contributions. The stated goal is to contribute extensions upstream over time.

Already upstreamed (with Tarides assistance):
- **Labelled tuples** and **immutable arrays** in OCaml 5.4.
- **Atomic record fields** in OCaml 5.4 (PR [#13404](https://github.com/ocaml/ocaml/pull/13404)).

Wish-list for upstreaming (per OxCaml 5.4 merge wiki):
- PRs [#753](https://github.com/oxcaml/oxcaml/pull/753), [#871](https://github.com/oxcaml/oxcaml/pull/871), [#896](https://github.com/oxcaml/oxcaml/pull/896), [#1036](https://github.com/oxcaml/oxcaml/pull/1036) are flagged as "it would have been useful to have upstreamed already."

No public roadmap dates exist for mode-system upstreaming. Jane Street's blog post (June 2025) says: "Our hope is that these extensions can over time be contributed to upstream OCaml."

Sources: [Jane Street Blog "Introducing OxCaml"](https://blog.janestreet.com/introducing-oxcaml/) (2025-06-14); [Tarides Blog](https://tarides.com/blog/2025-07-09-introducing-jane-street-s-oxcaml-branch/) (2025-07-09); [oxcaml/oxcaml Wiki "Notes on merging 5.4"](https://github.com/oxcaml/oxcaml/wiki/Notes-on-merging-5.4) (2026-04-02).

---

## 5. Effet-specific feature mapping

| Effet design question | OxCaml feature | Maturity | Notes |
|-----------------------|----------------|----------|-------|
| Make `Effect.t` portable across domains | `@@ portable` modality on GADT constructors; `value mod portable` kind on type params | Stable | Every constructor argument that does not contain functions crosses portability automatically. For closures inside `Effect.t`, explicit `portable` annotation is required. |
| Stack-allocate `Effect.t` nodes | `local_` parameters; `stack_` keyword; `exclave_` returns | Stable | `Effect.t` values constructed and consumed within a single fiber can be `local`. Requires the interpreter to accept `local` AST nodes. |
| Statically enforce single-shot continuations | `once` mode on continuation functions | Stable | Any function passed as a continuation can be typed `@ once`. The type checker rejects calling it twice. |
| Pin `Eio.Switch.t` to its scope | `local` mode on the switch value | Stable in OxCaml; **unknown in Eio** | OxCaml's `local` is the canonical way to pin scopes. Eio itself does not annotate `Switch.t` with `local_`. A wrapper or migration to `Await`/`handled_effect` may be needed. |
| Cross-domain `Cause` aggregation | `Capsule.Data.t` for shared mutable cause state | Stable (expert API) | A `Cause` ref can live inside a capsule and be updated from multiple domains via `Capsule.Mutex.with_lock`. |
| Single-shot finalizers (acquire_release) | `once` mode on the release function | Stable | `val acquire_release : acquire:'a -> release:('a -> unit) @ once -> 'a` would statically enforce single-call release. |
| Capsule-protected runtime state | `Capsule.Data.t` + `Capsule.Mutex.t` | Stable | Failure refs and daemon lists can be branded to a private capsule, with the mutex as the only access path. |
| Domain-parallel `Resource` state | `Parallel.fork_join2` + capsules | Stable | `Resource` combinators that operate over collections can use `Parallel_scheduler` for domain parallelism. |
| Unboxed `Effect.t` representation | `[@@unboxed]` on wrapper types; unboxed tuples `#(...)` | Stable-ish | If `Effect.t` is a simple discriminated union with small payloads, `[@@unboxed]` on constructors reduces indirection. For multi-field nodes, unboxed tuples may help. |
| Atomic kinds for concurrent counters | `Portable.Atomic.t` | Stable | Replaces `ref` for counters that must be updated from multiple domains. |

**Critical gap:** Eio is not mode-annotated. Using Effet's existing Eio runtime under OxCaml will compile (as already proven: 141 tests pass under 5.2.0+ox), but to gain static guarantees (local Switch pinning, portable fibers, etc.), Effet must either:
1. Add mode-annotated wrapper modules around Eio, or
2. Replace Eio with Jane Street's `Await` + `Parallel` + `handled_effect` stack.

---

## 6. Tooling and ergonomics

### 6.1 ocamlformat

Jane Street maintains a fork: `janestreet/ocamlformat` (branch `jane`, last push 2026-04-03). It is explicitly advertised as part of the OxCaml toolchain on [oxcaml.org/get-oxcaml/](https://oxcaml.org/get-oxcaml/):

```bash
opam install -y ocamlformat merlin ocaml-lsp-server utop parallel core_unix
```

Caveats: The upstream `ocaml-ppx/ocamlformat` project does not know OxCaml syntax. You must use the Jane Street fork. The oxcaml/merlin 5.4 upgrade PR (#227, April 2026) specifically upgraded to ocamlformat 0.29.0 to avoid a bug in 0.28.x that reformatted more than necessary.

Sources: [janestreet/ocamlformat](https://github.com/janestreet/ocamlformat) (2026-04-03); [oxcaml.org Get OxCaml](https://oxcaml.org/get-oxcaml/) (2025-06-13).

### 6.2 Merlin / OCaml-LSP

- **Merlin fork:** `oxcaml/merlin`. Last push 2026-04-07. PR [#227](https://github.com/oxcaml/merlin/pull/227) upgraded it to upstream 5.4.
- **OCaml-LSP fork:** `oxcaml/ocaml-lsp`. Last push 2026-01-15. 5 open issues. Stars: 1 (low adoption signal).
- **Maturity:** Functional but small-team. The LSP fork exists and builds; its issue tracker is active but low-volume.

Sources: [oxcaml/merlin](https://github.com/oxcaml/merlin) (2026-04-07); [oxcaml/ocaml-lsp](https://github.com/oxcaml/ocaml-lsp) (2026-01-15).

### 6.3 Dune support

Dune 3.21+ supports OxCaml via custom repositories in `dune-workspace`:

```dune
(lang dune 3.21)

(repository
 (name oxcaml)
 (url git+https://github.com/oxcaml/opam-repository))

(lock_dir
 (repositories overlay oxcaml upstream))
```

And pinning the compiler:

```dune
(package
 (name hello-oxcaml)
 (depends
  (ocaml-variants
   (= 5.2.0+ox))))
```

Extension flags can be set per-library:

```dune
(library
 (name your_lib)
 (flags (:standard -extension-universe beta)))
```

**Dune OxCaml extension for parameterized libraries:** Since Dune 3.20, `(using oxcaml 0.1)` enables experimental stanzas for parameterized libraries (build-time dependency injection). These are only supported by the OxCaml compiler.

Source: [Dune docs "OxCaml Parameterised Libraries"](https://dune.readthedocs.io/en/stable/tutorials/oxcaml-parameterized-library/index.html) (2025-2026).

Source: [Dune docs "Setting up an OxCaml project"](https://dune.readthedocs.io/en/latest/tutorials/dune-package-management/oxcaml.html) (date not specified, docs current as of 2025-2026); [oxcaml.org Get OxCaml](https://oxcaml.org/get-oxcaml/) (2025-06-13).

### 6.4 Writing `@@ portable` in mlis

The syntax is supported on record fields, variant constructors, and `include`:

```ocaml
type 'a t = { payload : 'a @@ portable }

type 'a eff =
  | Async : (unit -> 'a) @ portable -> 'a eff

include S @@ portable
```

For function signatures in mlis, modes go on arrow types:

```ocaml
val fork : (unit -> 'a) @ portable -> 'a
```

Source: [oxcaml.org Modes Syntax](https://oxcaml.org/documentation/modes/syntax/) (2025-06-13).

### 6.5 Compiler error quality

The specific message "I gave up trying to find the simplest kind" was not found in the searched OxCaml documentation or issue trackers. The canonical behavior for kind-inference failure is:

> "If layout inference does not work, you will get an error asking you to write a layout annotation."

It is unknown whether the exact wording "gave up" has been rephrased in newer builds. Treat error-message polish as an open question.

Source: [oxcaml.org Unboxed Types Intro](https://oxcaml.org/documentation/unboxed-types/01-intro/) (2025-06-13).

---

## 7. Known limitations

### 7.1 OxCaml platform limitations

- **No Windows support.** Use WSL 2.
- **No musl-based Linux** (Alpine).
- **No architectures other than x86_64 or ARM64.**
- **SIMD extension not on ARM.**

Source: [oxcaml.org Get OxCaml](https://oxcaml.org/get-oxcaml/) (2025-06-13).

### 7.2 Type-system limitations

- **Modules with modes:** "Support for modules with modes is being worked on and not ready for wide adoption." You cannot yet write `module M @@ portable`.
- **First-class modules + exceptions:** A known soundness hole where first-class modules do not account for portability/contention of extension constructors defined inside them. Documented with a reproducible example in the modes reference.
- **Mutually recursive type definitions + layout inference:** May require manual kind annotations. No incorrect inference, but automation gaps exist.

Sources: [oxcaml.org Modes Syntax](https://oxcaml.org/documentation/modes/syntax/) (2025-06-13); [oxcaml.org Modes Reference](https://oxcaml.org/documentation/modes/reference/) (2025-06-13); [oxcaml.org Unboxed Types Intro](https://oxcaml.org/documentation/unboxed-types/01-intro/) (2025-06-13).

### 7.3 Effet-specific friction points

| Feature | Friction |
|---------|----------|
| Recursive `Effect.t` GADT | May trigger layout-inference failures requiring explicit `: value mod portable` annotations on type parameters. |
| Eio compatibility | Eio is not mode-annotated. `Eio.Switch.t` does not carry `local_` in its public type. To pin switches statically, Effet must wrap Eio or replace it with `Await`/`handled_effect`. |
| Effect handler composition | Jane Street's `handled_effect` uses `local` capabilities, which is a different model from Eio's direct `perform`/`effect`. Porting Effet's interpreter to `handled_effect` would be a redesign, not a drop-in. |
| `parallel_map` / `parallel_sequence` | Exact module names and API shapes in `janestreet/parallel` were not fully extracted from search; verify against the repo directly before depending on them. |

---

## 8. References

1. OxCaml — Modes Intro (2025-06-13). https://oxcaml.org/documentation/modes/intro/
2. OxCaml — Modes Reference (2025-06-13). https://oxcaml.org/documentation/modes/reference/
3. OxCaml — Modes Syntax (2025-06-13). https://oxcaml.org/documentation/modes/syntax/
4. OxCaml — Stack Allocation Intro (2025-06-13). https://oxcaml.org/documentation/stack-allocation/intro/
5. OxCaml — Stack Allocation Reference (2025-06-13). https://oxcaml.org/documentation/stack-allocation/reference/
6. OxCaml — Uniqueness Reference (2025-06-13). https://oxcaml.org/documentation/uniqueness/reference/
7. OxCaml — Uniqueness Intro (2025-06-13). https://oxcaml.org/documentation/uniqueness/intro/
8. OxCaml — Uniqueness Pitfalls (2025-06-13). https://oxcaml.org/documentation/uniqueness/pitfalls/
9. OxCaml — Kinds Intro (2025-06-13). https://oxcaml.org/documentation/kinds/intro/
10. OxCaml — Kinds Syntax (2025-06-13). https://oxcaml.org/documentation/kinds/syntax/
11. OxCaml — Kinds of Types (2025-06-13). https://oxcaml.org/documentation/kinds/types/
12. OxCaml — Unboxed Types Intro (2025-06-13). https://oxcaml.org/documentation/unboxed-types/01-intro/
13. OxCaml — Parallelism Intro (2025-06-13). https://oxcaml.org/documentation/parallelism/01-intro/
14. OxCaml — Parallelism Capsules (2025-06-13). https://oxcaml.org/documentation/parallelism/02-capsules/
15. OxCaml — Tutorials: Intro to Parallelism Part 1 (2025-06-13). https://oxcaml.org/documentation/tutorials/01-intro-to-parallelism-part-1/
16. OxCaml — Tutorials: Intro to Parallelism Part 2 (2025-06-13). https://oxcaml.org/documentation/tutorials/02-intro-to-parallelism-part-2/
17. OxCaml — Zero Alloc Checker (2025-06-13). https://oxcaml.org/documentation/miscellaneous-extensions/zero_alloc_check/
18. OxCaml — Get OxCaml (2025-06-13). https://oxcaml.org/get-oxcaml/
19. OxCaml — Documentation home (2025-06-13). https://oxcaml.org/documentation/
20. Jane Street Blog — "Introducing OxCaml" by Leo White (2025-06-14). https://blog.janestreet.com/introducing-oxcaml/
21. Tarides Blog — "Introducing Jane Street's OxCaml Branch!" (2025-07-09). https://tarides.com/blog/2025-07-09-introducing-jane-street-s-oxcaml-branch/
22. KC Sivaramakrishnan — "Data race freedom in OxCaml" (2026-05-07). https://kcsrk.info/ocaml/oxcaml/x-ocaml/blogging/2026/05/07/data-race-freedom-in-oxcaml/
23. KC Sivaramakrishnan — "Capsules: compile-time lock discipline in OxCaml" (2026-05-08). https://kcsrk.info/ocaml/oxcaml/modes/blogging/2026/05/08/capsules-in-oxcaml/
24. KC Sivaramakrishnan — "Linearity and uniqueness" (2025-06-04). https://kcsrk.info/ocaml/modes/oxcaml/2025/06/04/linearity_and_uniqueness/
25. Jane Street Blog — "Oxidizing OCaml: Locality" by Max Slater (date unspecified; pre-2025). https://blog.janestreet.com/oxidizing-ocaml-locality/
26. Jane Street Blog — "Oxidizing OCaml: Rust-Style Ownership" by Max Slater (date unspecified; pre-2025). https://blog.janestreet.com/oxidizing-ocaml-ownership/
27. `janestreet/parallel` GitHub repository (2025-05-27). https://github.com/janestreet/parallel
28. `janestreet/await` GitHub repository (2025-05-27). https://github.com/janestreet/await
29. `janestreet/handled_effect` GitHub repository (2025-04-27). https://github.com/janestreet/handled_effect
30. `janestreet/portable` GitHub repository (2025-05-27). https://github.com/janestreet/portable
31. `oxcaml/merlin` GitHub repository (last push 2026-04-07). https://github.com/oxcaml/merlin
32. `oxcaml/ocaml-lsp` GitHub repository (last push 2026-01-15). https://github.com/oxcaml/ocaml-lsp
33. `janestreet/ocamlformat` GitHub repository (last push 2026-04-03). https://github.com/janestreet/ocamlformat
34. `oxcaml/oxcaml` Wiki — "Notes on merging 5.4" (2026-04-02). https://github.com/oxcaml/oxcaml/wiki/Notes-on-merging-5.4
35. `oxcaml/oxcaml` Wiki — "List of upstream changes from 5.2.0 to 5.4.0 split by area" (date unspecified). https://github.com/oxcaml/oxcaml/wiki/List-of-upstream-changes-from-5.2.0-to-5.4.0-split-by-area
36. `oxcaml/merlin` PR #227 — "Upgrade to 5.4" (2026-04-01). https://github.com/oxcaml/merlin/pull/227
37. `oxcaml/oxcaml` PR #4826 — "Use unboxed versions to type block indices to flattened float fields" (2025-10-03). https://github.com/oxcaml/oxcaml/pull/4826
38. `oxcaml/oxcaml` Issue #5278 — "Implement improved zero-alloc analysis" (2026-01-20). https://github.com/oxcaml/oxcaml/issues/5278
39. `ocaml/ocaml` PR #13404 — "Atomic record fields" (2024-08-27). https://github.com/ocaml/ocaml/pull/13404
40. `ocaml/odoc` PR #1407 — "OxCaml: Support for unboxed named types" (2026-03-31). https://github.com/ocaml/odoc/pull/1407
41. `ocaml/odoc` PR #1410 — "OxCaml: Support for kind annotations" (2026-04-14). https://github.com/ocaml/odoc/pull/1410
42. `ocaml/odoc` Issue #1416 — "Support OxCaml modalities" (2026-04-14). https://github.com/ocaml/odoc/issues/1416
43. Dune documentation — "Setting up an OxCaml project" (current as of 2025-2026). https://dune.readthedocs.io/en/latest/tutorials/dune-package-management/oxcaml.html
44. `oxcaml/tutorial-icfp25` GitHub repository (2025-09-23). https://github.com/oxcaml/tutorial-icfp25
45. `ocaml-multicore/eio` GitHub repository (no OxCaml annotations found). https://github.com/ocaml-multicore/eio
46. `ocaml/odoc` Issue #1418 — "Support OxCaml `@zero-alloc` annotation" (2026-04-14). https://github.com/ocaml/odoc/issues/1418
47. `oxcaml/oxcaml` Issue #4447 — "LSP diagnostics and formatting is off by default" (2025-08-06). https://github.com/oxcaml/oxcaml/issues/4447
48. Gavin Gray — OxCaml ICFP 2025 tutorial slides (2025). https://gavinleroy.com/oxcaml-tutorial-icfp25/
49. Mark Elvers — "ONNX inference engine using OxCaml's SIMD intrinsics" (2026-03-13). https://www.tunbury.org/2026/03/13/oxcaml-inference/
50. Mark Elvers — "Pi Day 2026: OCaml vs OxCaml" (2026-03-14). https://www.tunbury.org/2026/03/14/pi-day/
51. Dune documentation — "OxCaml Parameterised Libraries with Dune" (2025-2026). https://dune.readthedocs.io/en/stable/tutorials/oxcaml-parameterized-library/index.html
52. `oxcaml/opam-repository` GitHub repository (2025-04-10). https://github.com/oxcaml/opam-repository
53. `janestreet/unboxed_datatypes` GitHub repository (2026-01-14). https://github.com/janestreet/unboxed_datatypes
54. `janestreet/ocamlformat` GitHub repository (2026-04-03). https://github.com/janestreet/ocamlformat

---

*End of dossier. All claims are sourced to URLs above. Items marked "unknown" indicate no source was found during research.*
