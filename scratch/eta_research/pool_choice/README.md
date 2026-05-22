# Eta.Pool Storage Choice Lab

This lab answers the question Eta-a55 left open: which idle-storage policy is
best for an Eta.Pool hot path under OxCaml/Eio constraints?

The first executable compares:

- Treiber LIFO over Portable.Atomic;
- mutex-protected LIFO;
- mutex-protected FIFO;
- Eio.Stream FIFO.

It intentionally reports both warm-reuse and fairness. A pool policy can win on
warm cache behavior while losing on starvation or allocation.

Run:

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_choice/storage_policy_bench.exe
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_choice/pool_protocol_bench.exe
~~~
