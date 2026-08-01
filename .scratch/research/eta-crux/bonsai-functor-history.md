# Bonsai public functor history, Cont migration, and Incremental generativity

Date: 2026-08-01.

## Scope

This report checks Bonsai's old `Make (Incr) (Event)` surface and its removal.
It also separates that change from Proc-to-Cont and checks current Incremental
generativity. The final comparison applies these facts to Eta Crux ticket 03.

Method: local git objects and file contents under
`/home/ribelo/projects/github/bonsai` and
`/home/ribelo/projects/github/incremental`.

## Short answers

| Question | Answer from sources |
|---|---|
| Did Bonsai expose a public functor? | **Yes.** `module Make (Incr : Incremental.S) (Event : T)` in v0.13 (`fb135cb`). |
| When / how did that change? | **Removed in** `84f697e` (2020-06-05). Public library stopped taking `Incr`/`Event` parameters and instead depended on fixed packages `incr_dom.ui_incr` and `virtual_dom.ui_event`. |
| Is Proc→Cont the same change? | **No.** Proc appears in 2020 (around `991d5ad` / documented `docs/proc.md` at `a6e0a0f`). Cont / `local_ graph` appears in 2024 (`1e63e35`, CHANGES v0.17). They are separate API eras. |
| Is Incremental still functorized? | **Yes.** `module Make () : S` remains generative in current `incremental_intf.ml`. |

---

## 1. Public functor era (verified)

### 1.1 Commit and surface

- Commit: `fb135cba232180c4865526f875de8c5faea72172` (`fb135cb`), subject `v0.13.0`,
  2019-11-18.
- `src/bonsai.mli` at that commit (full file):

```ocaml
module type S = Component.S

(** Bonsai can be used with any Incremental-style UI framework.  The parameters for the
    Bonsai component functor are an instance of Incremental (used to re-evaluate the UI
    only when the UI model has changed) and an opaque Event.t type (which is used to
    schedule actions).

    The recommended use of this functor is to bind the name [Bonsai] to its invocation.
    For example, [Bonsai_web]'s [import.ml] has:

    {[
      module Incr = Incr_dom.Incr
      module Vdom = Virtual_dom.Vdom
      module Bonsai = Bonsai.Make (Incr) (Vdom.Event)
    ]}
    ...
*)
module Make (Incr : Incremental.S) (Event : T) :
  S with module Incr := Incr with module Event := Event
```

- Implementation: `src/bonsai.ml` is `module Make (Incr) (Event) = Component.Make (Incr) (Event)`.
- `Component.Make` instantiates `Incr_map.Make (Incr)` and `Snapshot.Make (Event)`
  (`fb135cb:src/component.ml`).

### 1.2 What primary sources state about purpose

Stated in the `Make` doc comment only:

1. Bonsai works with **any Incremental-style UI framework**.
2. Parameter 1 is an **Incremental instance** for re-evaluating the UI when the
   model changes.
3. Parameter 2 is an **opaque `Event.t`** used to schedule actions.
4. Recommended call pattern is host-side:
   `Bonsai.Make (Incr_dom.Incr) (Vdom.Event)`.

No other first-party rationale for *why* a functor (vs a fixed package) is
stated in that mli. Do not invent further motives.

### 1.3 Functor still present immediately before removal

At `84f697e^`:

- `src/bonsai_intf.ml` still ends with
  `module Make (Incr : Incremental.S) (Event : Event.S) : ...`
- `Event` had grown from bare `T` (v0.13) to `Event.S` with `sequence` and
  `no_op` (`84f697e^:src/event.mli`).
- Call sites still used the functor: `web/import.ml`, `test/import.ml`,
  `docs/bonsai_mdx/import.ml` all `include Bonsai.Make (Incr) (Event)`.
- `src/dune` depended on generic `incremental` (and `incr_map`), not
  `incr_dom.ui_incr`.

---

## 2. Removal of the public functor (verified)

### 2.1 Commit

- Commit: `84f697e9b5eb9345455b970bf1f29833144edd42` (`84f697e`),
  subject `v0.15-preview.123.01+11`, **2020-06-05**.
- Author/committer: Xavier Clerc (public-release style version tag. no prose
  commit body explaining the design).

### 2.2 What the tree change shows (facts, not inferred motive)

After `84f697e`:

| Before (`84f697e^`) | After (`84f697e`) |
|---|---|
| Public `module Make (Incr) (Event)` | No public `Make` in `src/bonsai.mli` |
| `src/dune`: `incremental`, `incr_map` | `src/dune`: `incr_dom.ui_incr`, `virtual_dom.ui_event` |
| `bonsai.opam` depends on `incremental` + `incr_map` explicitly | `incremental` / `incr_map` dropped from opam. still depends on `incr_dom` and `virtual_dom` |
| Host applies functor in `import.ml` | Library is pre-bound. `bonsai.mli` is `include Legacy_api` + `module Proc` |

`84f697e:src/bonsai.mli` begins:

```ocaml
include module type of Legacy_api
module Proc : module type of Proc with module Private := Proc.Private
...
```

So the public library became a **single pre-instantiated Bonsai**, not a
framework-parameterized functor.

### 2.3 Stated rationale for *this* removal

**Not found in primary sources consulted:**

- Commit message is only a version string.
- `changelog.md` at `84f697e` still starts at `2020-02-27` and does **not**
  mention removing `Make` or hard-wiring `ui_incr` / `ui_event`.
- No adjacent design note in that commit names “we no longer support arbitrary
  Incremental frameworks.”

What *is* stated nearby (but about other topics):

- README at `84f697e` still describes Bonsai as building on Incr_dom lessons and
  hiding Incremental from users (`README.md`). That is about the programming
  model, not explicitly about dropping the functor.
- `docs/incrementality.md` (snapshot `a6e0a0f`, days later) says Incremental is
  almost nowhere in the user API and is added under the hood. Again: user
  opacity of Incr nodes, not functor generativity.

**Uncertainty:** An internal reason can exist (single web host,
package simplification, Event API consolidation). That reason is **not** written
in the open commits/changelogs inspected here. Report only the structural
change.

---

## 3. Proc is not the functor removal. Cont is later still

### 3.1 Timeline (distinct events)

```text
2019-11  fb135cb     public Make (Incr) (Event)   [functor era]
2020-04  991d5ad     src/proc.ml(i) first appear  [Proc introduced]
2020-06-05 84f697e   public Make removed. ui_incr/ui_event deps
2020-06-11 a6e0a0f   docs/proc.md, changelog "Bonsai.Proc module added"
2024-02  1e63e35     src/cont.ml(i), docs/upgrade/local-graph.mdx
current  HEAD        bonsai.mli: Cont default, Proc intermediate
```

### 3.2 What Proc changed (primary rationale exists)

`docs/proc.md` at `a6e0a0f` is first-party and explicit:

- Old primary abstraction was an **Arrow** `('a, 'b) Bonsai.t`.
- Arrow APIs are hard to name intermediates, force tupling, risk duplicated
  work, and make `if_` obtuse (shared input product).
- Proc splits into:
  - `'a Computation.t` — method of computing `'a`, owns state machine. **each
    use is independent** (no shared state/work across separate `let%sub`s).
  - `'a Value.t` — shared incremental value (applicative).
- `let%sub : 'a Computation.t -> f:('a Value.t -> 'b Computation.t) -> 'b Computation.t`
  is **variable substitution**, not monadic bind.
- Inspired by Arrow Calculus. accompanied by `ppx_let` extension.

`changelog.md` (current file, entry **2020-06-10**):

> `Bonsai.Proc` module added. To read more, check out `./docs/blog/proc.md`.

(Path in that note is `docs/blog/proc.md`. the file in-tree at `a6e0a0f` is
`docs/proc.md`. Path drift only.)

**None of that text is about `Make (Incr) (Event)`.** Proc is a *component
description* API change on top of an already-incremental engine.

### 3.3 What Cont changed (primary rationale exists)

Current `src/bonsai.mli`:

> The Bonsai API is currently in an intermediate state. It is transitioning from
> the "old" [Proc] API to the "new" [Cont] API. The [Cont] API is now the
> default … Current Bonsai documentation can be found in [cont.mli].

`CHANGES.md` Release v0.17.0:

> Rewrote entire bonsai API. The new version is inside of the `Bonsai.Cont`
> namespace.
> Add documentation about changes and upgrade strategies between proc and cont.

`docs/upgrade/local-graph.mdx` at `1e63e35` states mechanical migration:

1. `'a Value.t` → `'a Bonsai.t`.
2. `'a Computation.t` → `local_ Bonsai.graph -> 'a Bonsai.t`.
3. Prefer passing `graph` over `let%sub`.
4. Components can return **tuples/records of `Bonsai.t`s** because a single
   `Computation.t` return is no longer forced.

`cont.mli` (current) states the phase split:

- `type 'a t` — “a `'a` that changes over time.”
- `type graph` — required for non-pure construction. **Always `local_`.**
- Phase 1: graph building (`local_ graph` available).
- Phase 2: runtime — modifying the graph is no longer permitted.

**None of that text reintroduces or removes a public Incremental functor.** Cont
changes how construction context and value/computation split are *spelled*.

---

## 4. Incremental remains generative

Current `/home/ribelo/projects/github/incremental/src/incremental_intf.ml`:

```ocaml
(** [Make] returns a new incremental implementation. [Make] uses [Config.Default ()]. *)
module Make () : S
```

Opening documentation (same file):

> one first creates a new instance via:
> `module Inc : Incremental.S = Incremental.Make ()`
>
> … Since [Incremental.Make] is a **generative functor**, the type system
> enforces that different applications of the functor deal with **disjoint sets
> of incrementals**.

So:

- Bonsai *used* to take an already-built `Incremental.S` as a parameter.
- Incremental *still* creates isolated graph universes via generative `Make ()`.
- After 2020-06, public Bonsai no longer lets application code choose which
  Incremental universe Bonsai is built against. the library is wired to the
  fixed `ui_incr` (today: `bonsai_concrete.ui_incr` in current `src/dune`).

---

## 5. Pros and cons of the three API shapes

Rules for this section:

- **Stated by sources** → marked *stated*.
- **Direct structural consequences of the types/deps** → marked *structural*.
- **Not claimed by sources** → omitted or labeled *uncertain*.

### 5.1 Old public `Bonsai.Make (Incr) (Event)`

**What it is (stated + structural):** This is a generative-style host binding.
The host selects an `Incremental.S` and an event type. The result shares its
`Incr` and `Event` modules with the host (`fb135cb` mli).

| | |
|---|---|
| **Pros (stated)** | Works with “any Incremental-style UI framework”. Event type is opaque and host-chosen. recommended pattern shares host Incr/Event with Bonsai. |
| **Pros (structural)** | Type system prevents mixing components from different `Make` applications if their `Incr`/`Event` types differ. library package need not hard-depend on one UI event module. |
| **Cons (structural)** | Every consumer must apply the functor and keep `Incr`/`Event` consistent. API surface is a module type `S`, not a concrete module. Event later needed `sequence`/`no_op` (`Event.S`), so “opaque `T`” was incomplete for composition. |
| **Cons (uncertain / not stated)** | Why Jane Street abandoned multi-framework parameterization is not documented in the commits inspected. |

### 5.2 Current Cont API: one `'a t` + `local_ graph`

**What it is (stated):** default public API (`bonsai.mli`, `cont.mli`). Values
that change over time are `'a t`. Construction that allocates state needs
`local_ graph`. Graph building and runtime are separate phases.

| | |
|---|---|
| **Pros (stated)** | Mechanical upgrade from Proc. components can return multiple `Bonsai.t`s without packing. `let%sub` often unnecessary. graph parameter marks “uses primitives.” |
| **Pros (structural)** | Single concrete module (no host functor). `local_` encodes “graph only during construction”. pure mapping stays on `'a t` without graph. |
| **Cons (stated, migration docs)** | Large rewrite from Proc. intermediate dual API (Proc still exists somewhere). |
| **Cons (structural)** | Engine Incremental instance is **not** a user parameter. The library depends on the fixed `ui_incr` and effect stack (`src/dune`). The graph handle is an explicit extra argument during construction. `local_` is an OxCaml modes feature that is not portable to upstream OCaml 5.4. |

### 5.3 Graph-neutral description API (Eta Crux ticket 03 candidates)

Ticket 03 (`docs/wayfinder/eta-crux-first-principles/issues/03-public-computation-api.md`)
asks for sketches comparing, among others:

- one public `'a t` + construction context.
- separate value vs structural-computation types.
- single hidden type.
- explicit graph / generative modules / rank-2 encodings so invalid
  cross-application composition fails in types.
- while keeping `eta_signal` private.

This is **not** a Bonsai API. Comparison below is structural against the two
Bonsai eras, without inventing a Jane Street rationale for Eta.

| Shape | Relation to Bonsai history | Structural pros | Structural cons |
|---|---|---|---|
| **One `'a t` + construction context** (Cont-like) | Closest to current Cont | One mental type for “changing value”. context marks allocation. can keep engine private if context is abstract | Must define context lifetime (modes, phantom, or rank-2). easy to over-thread context. does not by itself isolate two engine instances |
| **Value + Computation split** (Proc-like) | Closest to Proc 2020–2024 | *Stated* Proc benefit: separates state-machine instantiation from value sharing. independent instances via separate `sub` | Two types + `sub`/`let%sub` ceremony. packing single return values. Cont migration docs treat this as the pain being removed |
| **Public generative `Make (Engine)`** (old Bonsai-like) | Closest to pre-2020 functor | Isolates engine universes like Incremental’s generative `Make ()`. multiple hosts/tests can each own a graph world | Host must apply functor. forces engine module type into public surface unless carefully sealed. Bonsai itself later abandoned this for a fixed binding |
| **Fixed engine implementation, no public functor** (post-`84f697e` Bonsai package shape) | Closest to post-2020 packaging | Simple `open Eta_crux`. one engine and event policy | Applications cannot substitute the engine or event implementation. root isolation needs another mechanism |
| **Graph-neutral descriptions with a private engine for each root** (selected Eta Crux shape) | No exact Bonsai era. separates public descriptions from engine instances | Ordinary reusable functions, multiple isolated roots, no public graph capability | The interpreter must enforce node identity and root isolation. no public brand proves root affinity |

Ticket 03 also requires pure map, applicative composition, dynamic bind, one state
machine, one child, and root construction. Application code cannot contain raw
signals, observers, or stabilization.

These requirements are independent of package functorization. Proc and Cont
both hide Incremental nodes from normal users. Incremental remains functorized
internally (`docs/incrementality.md`, Cont docs).

---

## 6. Implications for Eta Crux (facts only)

1. **Do not treat Cont as “Bonsai stopped being functorized.”**
   Functor removal ≈ 2020-06. Cont ≈ 2024. Different decisions.

2. **Do not treat “Incremental is generative” as “Eta Crux public API must be a
   functor.”**
   Incremental’s generativity isolates *engine instances*. Bonsai’s public
   functor used to re-export that choice. Bonsai later fixed the choice at the
   package boundary while Incremental remained generative internally.

3. **If Eta Crux wants isolation of multiple independent apps/tests in one
   process**, primary Incremental docs show generativity as the *engine*
   mechanism. Whether that appears as public `Make ()`, an abstract runtime
   handle, or a single global is an Eta design choice **not settled by Bonsai
   history text**.

   Eta Crux can apply `Eta_signal.Make` privately for each root while it keeps a
   non-functorized public description API. Bonsai history neither requires nor
   prohibits that combination.

4. **If Eta Crux wants Cont-like call sites**, ticket 03’s “one `'a t` +
   construction context” is the closest Bonsai analogue. use Cont’s *stated*
   phase split, not unstated myths about functors.

5. **If Eta Crux wants Proc-like explicit instance vs share**, Proc’s *stated*
   Computation/Value split and independent `let%sub` instances are the reference.
   Cont’s upgrade doc is evidence Jane Street later preferred collapsing that
   split for ergonomics.

---

## 7. Source checklist

| Claim | Source |
|---|---|
| Public `Make (Incr) (Event)` at v0.13 | `fb135cb:src/bonsai.mli`, `component.ml` |
| Functor docs: any Incremental UI framework + Event | same mli |
| Functor gone. `ui_incr` + `ui_event` deps | `84f697e` `src/bonsai.mli`, `src/dune`, `bonsai.opam` vs parent |
| No prose rationale in that commit | `git show -s 84f697e` |
| Proc introduced 2020. documented | `991d5ad` add `proc.*`. `a6e0a0f:docs/proc.md`. changelog 2020-06-10 |
| Cont 2024. default | `1e63e35` add `cont.*`. current `bonsai.mli`. CHANGES v0.17. `docs/upgrade/local-graph.mdx` |
| Cont phase/`local_ graph` | current `cont.mli` |
| Incremental still `Make ()` generative | current `incremental_intf.ml` |
| Current Bonsai fixed engine packages | current `src/dune` (`bonsai_concrete.ui_incr`, …) |

## 8. Uncertainties (explicit)

1. **Why** Jane Street removed the public functor is not written in the open
   commits/changelogs inspected. only *that* and *how* are solid.
2. Exact internal date Proc became the *default* vs opt-in `Bonsai.Proc` is
   only partially pinned (module exists 2020-04. docs say core namespace
   “unchanged for now” in `docs/proc.md`).
3. Whether any non-web host ever applied `Make` with a non-`Incr_dom` Incremental
   is not evidenced in this checkout’s history snippets.
4. Ticket 03 candidate ranking for Eta is **not** decided by this note. only
   historical analogies and structural tradeoffs are.

## 9. Bottom line

- **Old Bonsai functor:** real, documented as multi-framework Incremental + host
  Event binding. removed mid-2020 by hard-wiring UI Incremental/Event packages.
- **Proc→Cont:** later, separate ergonomics migration of the *description* API
  (Arrow → Computation/Value → single `t` + `local_ graph`).
- **Incremental:** still generative `Make ()`.
- For Eta Crux ticket 03: copy *laws and stated ergonomic lessons*, not a
  conflated “functor era” story. keep engine generativity and public description
  API as independent axes.
