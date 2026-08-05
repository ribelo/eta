# Slice 10 design — Eta Crux on one private Signal graph

Spec: `docs/wayfinder/eta-signal-direction/specification.md` §12.
Contract: public `eta_crux.mli` stays graph-neutral and source-compatible;
the custom engine (`crux_graph.ml`, `crux_graph_base.ml`,
`crux_graph_commit.ml`) and every `Eta_signal.Owner_transaction` use are
deleted.

## What the current engine actually is

`'a Crux_graph.t = { id; eval : transaction -> scope -> 'a computed }` —
a hand-rolled version-memoization graph over
`Owner_transaction.cell Cell_map.t` stores keyed by `(scope, node)`.
`eval` has three hidden side-channels on `transaction`:

1. memo cells (`transaction_get`/`transaction_set`) — replaced by Signal
   nodes themselves.
2. scope lifecycle (`fresh_scope`, `removed_scopes`) from `bind` and
   `assoc` — replaced by Signal branch lifecycles plus frame-carried
   manifests (below).
3. domain effects staged for commit (`added_endpoints`, `works`,
   `data_updates`, `commit_hooks`, `removed_jobs`, `added_revokers`) —
   replaced by the immutable frame's manifests applied by the root after
   publication ("Lifecycle and source effects run after root publication").

`crux_graph_commit.commit_transaction` is mostly Crux domain lifecycle
(scopes/jobs/revokers/endpoints activation and retirement) driven by what
eval staged. In the target, that lifecycle is driven by the frame
manifests, not by eval side-channels. `Owner_transaction` vanishes.

## Target internal shape

Per root (created in `Root.create`):

1. one private `module Signal = Eta_signal.Make (Observer_error) ()`
2. one `module Signal_map = Eta_signal_map.Make (Signal.Package)` adapter
3. one compiled root-frame signal
4. one private output observer without callbacks (owns demand so timers /
   sources inside the frame stay necessary)

Description compilation:

```ocaml
type 'a compiled = {
  signal : 'a Signal.signal;       (* value channel *)
  manifest : manifest Signal.signal; (* structural channel *)
}
type 'a t = { id : int; compile : compile_ctx -> 'a compiled }
```

The public combinators compile to the Signal algebra:

- `return` -> `Signal.const`
- `map` -> `Signal.map`
- `both` -> `Signal.map2`
- `cutoff ~equal` -> Signal cutoff node (`Cutoff.of_equal`)
- `bind` -> `Signal.bind` (branch identity + invalidation replace the
  memoized `child.id` comparison and `removed_scopes` staging)
- `State_machine.create` -> one private `Signal.Var` for the model plus a
  node mapping `(model, input)` to `(output, endpoint_manifest)`; actions
  stage `Signal.Var.set` plus a dormant transition effect
- `Assoc(Order).assoc` -> `Signal_map.Keyed(Order).mapi`; continuous key
  presence preserves child identity/model/endpoints, removal retires the
  incarnation, re-entry creates fresh state and endpoints (keyed-branch
  semantics, not reimplemented)
- data sources -> private `Signal.Var` cells advanced by the advancement
  protocol

Manifests travel as frame data, not side-channels: the root-frame signal
publishes `{ output; endpoints; lifecycle; sources }` with `Cutoff.never`
on the final node. The root diffs consecutive frames to activate/retire
scopes, endpoints, jobs, and revokers after pointer installation.

## Advancement (one non-idle step)

1. select one event (existing ingress machinery, unchanged)
2. validate endpoint incarnation against the current frame
3. stage model and dormant transition effect (`Signal.Var.set` calls +
   remember the dormant effect)
4. one `Signal.stabilize`
5. read the private candidate frame (`Signal.Observer.read` on the output
   observer)
6. build and validate one immutable root commit (diff manifests)
7. install one root-commit pointer under the root lock
8. return output and the mandatory post-commit token
9. driver delivers output before token start

Idle advancement performs no stabilization. Failure before pointer
installation preserves the prior Crux frame (Signal staging rolls back on
typed failure; the pointer simply never moves). A defect after
installation crashes the root before output delivery (existing phase
machinery).

## File plan

- NEW `lib/crux/crux_engine.ml` — description type + combinators compiled
  to Signal, frame/manifest types, state-machine cells, assoc via
  Signal_map Keyed.
- REWRITE `lib/crux/crux_root.ml` advancement to the 9-step protocol.
- DELETE `lib/crux/crux_graph.ml`, `crux_graph_base.ml`,
  `crux_graph_commit.ml`.
- REWRITE `lib/crux/crux_assoc.ml` onto Signal_map Keyed (or fold into the
  engine and delete the file).
- `crux_source.ml`, `crux_host.ml`, `crux_boundary.ml`, `crux_driver*.ml`,
  `crux_wire.ml` — adjust to frame-manifest driving; their protocol shape
  (post-commit tokens, batching, telemetry) stays.
- `eta_crux.ml/.mli` — public surface unchanged except internal wiring.

## Open risks to resolve during implementation

- Exact manifest diff semantics for endpoint incarnation validation
  (step 2) — the current code checks `endpoint.active` + scope ancestry.
- Whether `scope_state` survives as root-side bookkeeping driven by frame
  diffs (expected: yes, slimmed) or folds entirely into keyed-branch
  lifecycles (only if jobs/revokers can attach to branches — they cannot;
  they are Crux domain concepts).
- Crux timers stay Eta effects/sources (no Signal time description).

## Gates

```sh
nix develop -c dune build @install
nix develop -c dune runtest test/crux --force
nix develop -c dune runtest test/signal test/signal_map test/signal_stream --force
grep -rn "Owner_transaction" lib/   # empty
```
