# OTel Propagation Lab

This lab compares three propagation shapes.

- p_a_pair_only.ml: current-style trace_id * span_id external parent. It
  correlates a child span but cannot carry trace flags, tracestate, or baggage.
- p_b_core_context.ml: full context record in the runtime/core. It round-trips
  W3C-style headers and lets sampling read the parent flags.
- p_c_exporter_only.ml: header helpers outside the runtime. It can parse/inject
  but cannot make named, par, logs, or current context observe baggage or
  sampling flags.

Run: nix develop -c dune exec scratch/otel_propagation/runtime_smoke.exe

