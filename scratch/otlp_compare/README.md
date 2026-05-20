# OTLP Backend Re-comparison Lab

This scratch lab compares the current \`effet-otel\` hand-rolled OTLP/JSON transport
against an \`ocaml-opentelemetry\`-style adapter model after Yojson and trace
propagation landed.

The lab is intentionally research-only. It does not add an upstream dependency or
replace \`packages/effet-otel\`. The upstream model is based on the \`opentelemetry\`
0.90/0.91 opam files and source survey:

- batching enabled by default
- bounded queue plumbing
- HTTP retry with exponential backoff
- self diagnostics for retry/drop paths

Run:

\`\`\`sh
nix develop -c dune exec scratch/otlp_compare/runtime_smoke.exe
\`\`\`

The smoke tests exercise the axes that matter for the V-O7r decision:

- collector OK
- collector down
- collector intermittently failing
- collector slow / bounded queue pressure
- W3C context extract/inject ownership after Effet-2d0
