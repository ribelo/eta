# effet-stream research lab

This lab compares three candidate shapes for Effet streams.

- `s_a_channel_core.ml` — Channel is the internal core; Stream is a derived wrapper.
- `s_b_stream_core.ml` — Stream is the core GADT; Sink is a fold record.
- `s_c_eio_pipeline.ml` — each stage is backed by `Eio.Stream` and fibers.
- `s_b2_pull_core.ml` — stronger lazy pull-core with explicit cursor close.
- `s_d_eio_chunked.ml` — stronger Eio-native candidate with chunk queues and switch cancellation.
- `s_e_channel_transducer.ml` — Channel/transducer candidate with a byte/string split-lines example.
- `s_f_seq_pull.ml` — minimal `Seq.t`-style candidate; kept to demonstrate the early-close hazard.
- `runtime_smoke.ml` — runs the shared A/B/C scenario and resource cleanup checks.
- `benchmark_compare.ml` — compares pull-core and Eio chunked queue behaviour on 1M elements.
- `neg_*.ml` — negative tests. Add one file stem to `dune`'s `(modules ...)` list,
  build, record the compiler error, then remove it again.

The shared positive scenario is:

```ocaml
range 1 n |> map (( * ) 2) |> take 5 |> Sink.fold ( + ) 0 = 30
```

Each candidate also has a fake resource source that must run its close hook
when a downstream `take` stops early.
