# Pool Survival Lab

Eta-a55 asks whether connection pooling should be an eta-http-private recipe
or a public Eta primitive. This lab treats the pool as a dogfooding workload:
the important output is not just the pool shape, but what Eta makes awkward or
unsafe while building it.

## Artifacts

- common.ml: fake connection factory, stats, workload helpers.
- branch_a_internal_pool.ml: eta-http-shaped private pool.
- branch_b_eta_pool.ml: generic public Eta.Pool-shaped pool.
- runtime_smoke.ml: cancellation, bounded workload, shutdown, health, idle
  eviction, and in-use lifetime fixtures for both branches.
- allocation_probe.ml: rough allocation/time signal for 1,000 sequential
  acquire/use/release cycles.
- treiber_stack_probe.ml: LIFO Treiber stack probe over Stdlib.Atomic.
- portable_atomic_positive.ml: LIFO Treiber stack probe over Portable.Atomic,
  the OxCaml/Base/Core portable atomic API name found in oxmono.
- oxcaml_borrow_positive.ml: sealed local unique borrow handle positive
  compile probe.
- oxcaml_conn_unique_negative.ml: negative probe for handing out an aliased
  pooled connection as local unique.
- oxcaml_borrow_effect_capture_negative.ml: negative probe for capturing a
  local borrow into Eta's lazy Effect.sync.
- atomic_portable_negative.ml: negative probe showing Atomic.Portable is the
  wrong module path in the current OxCaml shell.

## Commands

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_survival/runtime_smoke.exe
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_survival/allocation_probe.exe
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_survival/treiber_stack_probe.exe
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_survival/portable_atomic_positive.exe
nix develop .#oxcaml -c dune build scratch/eta_research/pool_survival/oxcaml_borrow_positive.exe
~~~

Negative probes are compiled directly and are expected to fail:

~~~sh
nix develop .#oxcaml -c ocamlc -c scratch/eta_research/pool_survival/atomic_portable_negative.ml
nix develop .#oxcaml -c ocamlc -c scratch/eta_research/pool_survival/oxcaml_conn_unique_negative.ml
nix develop .#oxcaml -c ocamlc -I _build/default/packages/eta/.eta.objs/byte -c scratch/eta_research/pool_survival/oxcaml_borrow_effect_capture_negative.ml
~~~
