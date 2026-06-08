# 2026-05-24 Audit and Shipped-Gate Recheck

Question: after the Motel recheck and live-reach redaction fix, do the package
audit scripts and shipped-package tests still pass for the current Track O and
Track A tree?

Audit scripts:

```text
bash packages/eta-http/audit/run.sh
exit 0
Dependency sites: 285
Eta escape sites: 4

bash packages/eta-otel/audit/run.sh
exit 0
Dependency sites: 134
Eta escape sites: 33

bash packages/eta-ai/audit/run.sh
exit 0
Dependency sites: 102
Eta escape sites: 3

bash packages/eta-ai-openai/audit/run.sh
exit 0
Dependency sites: 45
Eta escape sites: 2

bash packages/eta-ai-anthropic/audit/run.sh
exit 0
Dependency sites: 35
Eta escape sites: 2

bash packages/eta-ai-openai-compat/audit/run.sh
exit 0
Dependency sites: 33
Eta escape sites: 2

bash packages/eta-ai-openrouter/audit/run.sh
exit 0
Dependency sites: 34
Eta escape sites: 2
```

Provider dependency manifest scan:

```text
packages/eta-ai-openai/dune
libraries: eta eta-ai eta-http

packages/eta-ai-anthropic/dune
libraries: eta eta-ai eta-http

packages/eta-ai-openai-compat/dune
libraries: eta eta-ai eta-http

packages/eta-ai-openrouter/dune
libraries: eta eta-ai eta-http

eta-ai provider opam files
production depends: ocaml, dune, eta, eta-ai, eta-redacted, eta-http
test/doc depends only: eio_main, alcotest, odoc
```

Focused eta-http gate:

```text
nix develop -c dune runtest packages/eta-http --force
exit 0
eta-http-security: 1 test run
eta-http: 77 tests run
negative TLS compile-fail fixtures passed
```

Shipped-package gate:

```text
nix develop -c eta-oxcaml-test-shipped
exit 0
eta-schema tests passed
ppx_eta: 2 tests run
eta-ai: 20 tests run
eta-ai-openrouter: 8 tests run
eta-ai-openai: 10 tests run
eta-ai-openai-compat: 6 tests run
eta-ai-anthropic: 10 tests run
eta-stream: 17 tests run
eta: 186 tests run
eta-otel: 29 tests run, including live Motel export tests
```

Verdict: accepted. Current audit catalogs, provider manifests, and shipped tests
agree with the worktree after the live-reach redaction fix. The remaining
release evidence gaps were later reclassified by V-AI-RED-AI-LIVE2: successful
OpenAI paid, Kimi Code, Z.ai, Moonshot, Together, and Fireworks canaries are
reopeners because the required account/product/billing state is unavailable.
