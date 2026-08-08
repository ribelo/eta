# eta_signal_map

`eta_signal_map` provides a persistent diffable map and keyed reactive
collections for Eta Signal. Install this package when an application needs
stable per-key signal state.

The authoritative APIs are:

- [`Eta_signal_map`](eta_signal_map.mli) for maps and keyed operators
- [`Eta_signal`](../signal/eta_signal.mli) for graph operations and diagnostics

## Package boundary

`eta_signal_map` is an optional sibling of `eta_signal`. It depends on the exact
same release of `eta_signal` because it uses the sealed `Package_graph` protocol.
The root `eta` package does not contain the map or keyed operator.

The runtime package has no Base, Core, Incremental, or `Incr_map` dependency.
Alcotest and QCheck are test-only dependencies.

See [ADR 0004](../../docs/adrs/0004-lean-eta-signal-with-a-sibling-eta-signal-map.md)
for the package and private-kernel decision.

## Install

```sh
opam install eta_signal_map
```

Use these libraries in an executable:

```lisp
(executable
 (name main)
 (libraries eta_signal eta_signal_map))
```

## Limits and footguns

- Do not mutate keys after insertion. Use an immutable key and a stable total
  order.
- Select the data cutoff before you publish mutable or structural data. The
  default cutoff is physical identity.
- Use persistent map edits when you need the shared-ancestry complexity bound.
- Do not retain a child signal after its key leaves the input.
- Use the deterministic gate for comparison and child-visit regressions. Use
  the benchmark output only as wall-time evidence.

Read the exact key, cutoff, child-lifecycle, diagnostic, and complexity rules in
[`eta_signal_map.mli`](eta_signal_map.mli).

## Quick start

```ocaml
module S = Eta_signal.Make (Eta_signal.No_observer_error) ()
module Signal_map = Eta_signal_map.Make (S.Package)

module Int_order = struct
  type t = int
  let compare = Int.compare
end

module M = Eta_signal_map.Map.Make (Int_order)
module K = Signal_map.Keyed (Int_order)

let get_ok = function
  | Ok value -> value
  | Error _ -> failwith "eta_signal_map example failed"

let () =
  let input = S.Var.create (M.of_list [ (1, 10); (2, 20) ] |> Result.get_ok) in
  let output =
    K.mapi (S.Var.watch input) ~f:(fun ~key ~data ->
        S.map (fun value -> key + value) data)
  in
  let observer =
    get_ok (S.Observer.observe output ~on_update:(fun _update -> Ok ()))
  in
  get_ok (S.stabilize ());
  M.to_list (get_ok (S.Observer.read observer))
  |> List.iter (fun (key, value) -> Printf.printf "%d -> %d\n" key value);
  get_ok (S.Var.set input (M.set 2 30 (S.Var.value input)));
  get_ok (S.stabilize ());
  get_ok (S.Observer.dispose observer)
```

The graph uses explicit stabilization. Constructing or updating a source does
not run stabilization automatically.

## Diagnostics

Use `S.stats ()` for graph counters. The nested `keyed` record contains keyed
node, child, reconciliation, diff, commit, and rollback data.

Use `S.to_dot ()` for a necessary-only graph. Set `dot_scope` to `All_valid` or
`All_including_invalid` when you need retained nodes or bounded tombstones.

## Development

```sh
nix develop -c dune runtest test/signal_map test/laws --force
nix develop -c dune build @signal-map-complexity
nix develop -c dune build @lib/signal_map/bench/bench
```

The deterministic complexity target covers maps and the real keyed operator
through one million entries. The benchmark alias writes wall-time evidence to
`_build/default/lib/signal_map/bench/signal_map_complexity.csv`. Wall time does
not fail the deterministic gate.
