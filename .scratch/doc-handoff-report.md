# Eta Documentation Update — Final Verification Handoff Report

Generated: 2026-06-15T22:10:11Z
Verifier: final-verification agent
Scope: README.md, AGENTS.md, docs/*.md, lib/eta/*.mli, lib/*/README.md, bench/README.md, and http-testsuite/README.md.

---

## 1. Changed files

From `git status --short` (27 modified tracked files, plus untracked research/artifact dirs):

```
 M AGENTS.md
 M README.md
 M bench/README.md
 M docs/background-work.md
 M docs/packages.md
 M docs/services.md
 M docs/tutorial-eta-ai.md
 M docs/tutorial-eta-otel.md
 M http-testsuite/README.md
 M lib/ai/README.md
 M lib/ai/anthropic/README.md
 M lib/ai/openai/README.md
 M lib/ai/openai_compat/README.md
 M lib/ai/openrouter/README.md
 M lib/eta/effect.mli
 M lib/eta/log_level.mli
 M lib/eta/runtime.mli
 M lib/eta/sampler.mli
 M lib/eta/tracer.mli
 M lib/http/README.md
 M lib/otel/README.md
 M lib/par/README.md
 M lib/schema/README.md
 M lib/schema_test/README.md
 M lib/sql/README.md
 M lib/stream/README.md
 M lib/test/README.md
```

Untracked: `.hill-climbing/`, `.scratch/doc-gap-report.md`, `.scratch/evidence/`, `.scratch/doc-handoff-report.md`, `bench/results/20260615T213905Z-1214cb407.json`.

---

## 2. Verification commands run and results

| Command | Result |
| --- | --- |
| `git diff --check` | **Clean** — no whitespace errors. |
| `git status --short` | **27 modified tracked files** (see section 1). |
| `grep -RInE '\b(eta-ai\|eta-otel\|eta-http\|eta-schema\|eta-stream\|eta-test\|eta-schema-test\|eta_ai-[a-z]+\|eta_ai_openai-[a-z]+\|eta_ai_anthropic-[a-z]+)\b' README.md AGENTS.md docs/*.md lib/*/README.md bench/README.md http-testsuite/README.md` | **No matches** — hyphenated package names have been normalized in the current working tree. The `git diff` shows the hyphenated forms were removed. |
| `nix develop -c dune build lib/eta --force` | **Succeeded** (only the dirty-git-tree warning from Nix). |
| `nix develop -c dune runtest test/eta --force` | **Passed** — 27/27 tests, `Test Successful in 1.134s`. |

No additional build/test commands were run. The full `dune build @install`, HTTP/AI/SQL provider suites, and `eta-oxcaml-test-shipped` gate were not exercised in this verification pass.

---

## 3. Fixed gaps since the previous handoff

| Gap report item | Status |
| --- | --- |
| `AGENTS.md` claimed `Eta.Par` lives in the root `eta` package | **Fixed** — now states `Eta.Par` lives in the optional `eta_par` package and the root `eta` package contains only the effect description and interpretation core. |
| `AGENTS.md` core-module list was incomplete | **Fixed** — expanded to include `Syntax`, `Supervisor`, `Channel`, `Queue`, `Pubsub`, `Pool`, `Semaphore`, `Sampler`, `Logger`, `Meter`, `Log_level`, `Mutable_ref`, `Random`, and `Trace_context`. |
| `docs/services.md` used `Runtime.create` under `open Eta` | **Fixed** — now uses `Eta_eio.Runtime.create`. |
| `docs/tutorial-eta-otel.md` used hyphenated package names and `Runtime.create` | **Fixed** — `eta-otel` → `eta_otel`, `eta-http` → `eta_http`, and `Runtime.create` → `Eta_eio.Runtime.create`. |
| `docs/tutorial-eta-ai.md` used hyphenated package names and wrong test paths | **Fixed** — provider package names normalized to underscores; the core AI gate at line 366 now points to `test/ai/core` instead of `lib/ai`. |
| `lib/http/README.md` claimed edge-server readiness without audit cross-reference | **Fixed** — now softened with a pointer to `docs/http-server-production-readiness-audit.md` and explicit missing pieces (HTTPS ALPN server, TLS server, WebSocket server). |
| `lib/ai/*/README.md` provider test paths pointed to `lib/ai/...` | **Fixed** — all provider READMEs now point to `test/ai/<provider>`. |
| Hyphenated package names in edited docs/READMEs | **Fixed** — current files contain no remaining hyphenated forms for the tracked package names (`eta-ai`, `eta-ai-*`, `eta-otel`, `eta-http`, `eta-schema`, `eta-stream`, `eta-test`, `eta-schema-test`). |
| `README.md` lines 387/448 used `eta-otel` / `eta-http` | **Fixed** — now use `eta_otel` / `eta_http`. |

---

## 4. Remaining documentation gaps

### 4.1 Source-code-dependent or API-level gaps

| File | Gap | Severity |
| --- | --- | --- |
| `lib/otel/README.md` line 132 | The `~runtime_factory` type is written as `Eta.Capabilities.tracer -> unit Eta.Runtime.t`. OCaml syntax requires the type parameter before the module path (`'err Eta.Runtime.t`), so this approximation is misleading. | should-fix |

### 4.2 Gaps from the original report that are still open

| File | Gap | Severity |
| --- | --- | --- |
| `lib/eta/*.mli` | No top-level `eta.mli`; every module is public, so users cannot distinguish stable API from incidental modules. | should-fix |
| `lib/eta/effect.mli` | High-footgun combinators (`race`, `par`, `for_each_par`, `uninterruptible`, `daemon`, `with_background`) have detailed docstrings but no one-line examples. | should-fix |

### 4.3 Observations (not flagged as errors)

| File | Observation |
| --- | --- |
| `docs/packages.md` lines 29–30 | Prose refers to unqualified `Runtime.create`; this is acceptable as shorthand because the surrounding text explicitly names `Eta_eio.Runtime.create` and `eta_jsoo`. Not flagged as an error. |
| `lib/ai/README.md` line 11 | Uses `eta_http-backed` as a compound adjective. The package name itself (`eta_http`) is correct, so this is acceptable prose. |
| `lib/otel/README.md` line 38 | `eta-oxcaml-init` is the Nix shell helper command, not an opam package name. Not flagged as an error. |
| `docs/tutorial-eta-ai.md` line 1 | Title reads `eta_ai Core Tutorial` without backticks around the package name. Minor style inconsistency; not a correctness error. |

---

## 5. Issues found (summary)

1. **Hyphenated package names have been fully normalized in the edited files.** The verification grep returned no remaining hyphenated forms for the tracked package names.
2. **Wrong `Runtime.create` examples are fixed.** `README.md`, `docs/services.md`, and `docs/tutorial-eta-otel.md` now use `Eta_eio.Runtime.create`. `lib/stream/README.md` also uses `Eta_eio.Runtime.create`.
3. **AI test paths are fixed.** `docs/tutorial-eta-ai.md` points to `test/ai/core`, and all provider READMEs point to `test/ai/<provider>`.
4. **`lib/otel/README.md` `runtime_factory` type signature is still syntactically misleading.** This is the only source-code-dependent documentation gap that remains from the normalization pass.
5. **No top-level `eta.mli` or explicit stable-module roster** remains, leaving API stability unclear.
6. **No whitespace errors, and the core `lib/eta` build and `test/eta` suite are green.**

---

## 6. Recommendation

The editing agents resolved the highest-priority boundary error in `AGENTS.md`, normalized all tracked hyphenated package names, corrected the runtime-creation examples across the edited docs, fixed the AI core and provider test paths, softened the HTTP server readiness claim, and updated the package-boundary wording. Before the documentation update can be considered fully complete, the following should be addressed:

- Correct the `runtime_factory` type signature in `lib/otel/README.md` to valid OCaml syntax (`Eta.Capabilities.tracer -> 'err Eta.Runtime.t`, with an explanation that the concrete error row is usually `unit`).
- Optionally add a top-level `eta.mli`/stable-module roster and one-line examples for the highest-footgun `Effect` combinators.
