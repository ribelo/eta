# Eta OTel + AI Completion Audit

Date: 2026-05-24

Status: complete under the currently available provider-account scope. Track O
and Track A are implemented to the current evidence level. Successful live
canaries that require unavailable accounts, product scope, or billing state are
recorded as reopeners rather than completion blockers.

This audit is a current-state checklist for docs/research/objectives/eta-otel-and-eta-ai.md.
It records what is proven by files and commands in this worktree, what is only
partially proven, and what remains open.

## Evidence Snapshot

Recent verification:

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

    bash packages/eta-redacted/audit/run.sh
    exit 0
    Dependency sites: 0
    Eta escape sites: 0

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

    nix develop -c dune runtest packages/eta-http --force
    exit 0
    eta-http-security: 1 test run
    eta-http: 77 tests run

    nix develop -c eta-oxcaml-test-shipped
    exit 0
    eta-schema, ppx_eta, eta-redacted, eta-ai, eta-ai providers, eta-stream, eta, eta-otel passed

Live checks:

    nix develop -c dune runtest packages/eta-otel --force
    exit 0
    29 tests run, including live Motel trace/log/metric export tests

    nix develop -c bash scratch/eta_ai_v1/probes/live_reach/run.sh openai
    exit 1
    OpenAI reached provider but returned status 401 invalid_api_key

Key presence:

    OPENAI_API_KEY=present
    KIMI_FOR_CODING_API_KEY=present
    NOVITA_AI_API_KEY=present
    ZAI_API_KEY=present
    MOONSHOT_API_KEY=present
    GROQ_API_KEY=present
    DEEPSEEK_API_KEY=present
    PERPLEXITY_API_KEY=present
    TOGETHER_API_KEY=missing
    FIREWORKS_API_KEY=missing

Expanded AP3 live reach:

    nix develop -c bash scratch/eta_ai_v1/probes/live_reach/run.sh deepseek groq kimi-code novita zai moonshot perplexity
    exit 1
    Groq, DeepSeek, Novita, and Perplexity passed
    Kimi Code reached provider and returned product-scope 403
    Z.ai reached provider and returned insufficient-resource 429
    Moonshot reached provider and returned insufficient-balance 429

## Requirement Audit

| Requirement | Current evidence | Status |
| --- | --- | --- |
| Eta-1yb prerequisites available before Track O/A | eta-oxcaml-test-shipped passed Eta tests covering Redacted, LogLevel, MutableRef, and Semaphore. | Proven in current tree |
| Track O research R-T0..R-T3 recorded | scratch/eta_otel_v2/r_t0_transparent_cost, r_t1_peer_analysis, r_t2_otlp_capability_inventory, and r_t3_exporter_on_eta_http each have verdict artifacts; journal entries V-Otel-R-T0..V-Otel-R-T3 exist. | Proven |
| Track O OS0..OS6 implemented and recorded | packages/eta-otel, package ADRs/audits, scratch/eta_otel_v2/os6_cutover, and journal entries V-Otel-OS3..V-Otel-OS6; current objective says OS0..OS6 landed. | Proven to current artifact level |
| OTLP/HTTP via eta-http and recursion suppression | eta-otel ADR 0001, eta-otel adversarial tests, V-Otel-OS3, V-Otel-MOTEL-RECHECK; eta-otel tests include self-recursion and Motel live export. | Proven |
| W3C trace context and LogLevel preservation | Eta shipped tests cover trace context and LogLevel; eta-otel tracer tests include withSpanContext and live OTLP export. | Proven by shipped tests |
| Track O existing functional regression surface | dune runtest packages/eta-otel --force passed 29 tests including Tracer, Logger, Metrics, adversarial, and Motel suites. | Proven |
| Phase A-R before production eta-ai | docs/research/objectives/eta-ai-shape-decision.md exists and records A1..A5 verdicts before AC/AP journal entries; scratch probes exist under scratch/eta_ai_v1/probes. | Proven by artifact chronology in journal |
| A1 provider diff | provider_matrix.md, verdict.md, and V-AI-A1. | Proven |
| A2 SSE streaming | streaming_sse probe, eta-ai ADR 0002, and V-AI-A2; eta-ai streaming tests pass. | Proven, with public Eta_stream.Stream intentionally deferred |
| A3 schema integration | schema probe, eta-schema ADR 0001, and eta-ai ADR 0003. | Proven as deferred from v1 |
| A4 tokenizer triage | tokenizer probe verdict and V-AI-A4. | Proven as deferred from v1 |
| A5 telemetry seam | telemetry probe, eta-ai ADR 0004, eta-ai telemetry tests, and V-AI-A5. | Proven |
| AC0..AC7 eta-ai core | packages/eta-ai, audit catalogs, ADRs 0001..0005, README/tutorial, 20 eta-ai tests in shipped gate, and journal entries V-AI-AC0-AC1..V-AI-AC7. | Proven |
| eta-redacted package boundary | packages/eta-redacted, eta-redacted.opam, Eta.Redacted compatibility alias, direct Eta_redacted usage in eta-ai/provider auth, V-AI-RED-AI-LIVE2. | Proven |
| AP1 OpenAI package | packages/eta-ai-openai, provider ADR/audits/README, 10 offline tests, V-AI-AP1; live reach reached OpenAI through eta-http and returned a typed provider error; successful paid canary is a funded-account reopener. | Proven under available-account scope |
| AP2 Anthropic package | packages/eta-ai-anthropic, provider ADR/audits/README, 10 offline tests, V-AI-AP2; live reach passed claude-haiku-4-5-20251001. | Proven to current live-canary level |
| AP3 OpenAI-compatible package | packages/eta-ai-openai-compat, provider ADR/audits/README, 6 offline tests, V-AI-AP3; Mistral/Groq/DeepSeek/Novita/Perplexity live canaries passed; Kimi Code/Z.ai/Moonshot reached provider APIs but are blocked by product/account/billing state; Together/Fireworks accounts are absent. | Proven under available-account scope |
| AP4 OpenRouter package | packages/eta-ai-openrouter, provider ADR/audits/README, 8 offline tests, V-AI-AP4; OpenRouter live canary passed openai/gpt-4o-mini. | Proven to current live-canary level |
| Provider dependency policy | Provider library stanzas and generated opam files use eta-redacted explicitly for API-key redaction; provider production deps are ocaml/dune/eta/eta-ai/eta-redacted/eta-http. | Proven |
| Audit catalogs from day one | Audit files and scripts exist for eta-redacted, eta-http, eta-otel, eta-ai, and provider packages; all updated audit scripts exited 0. | Proven for current tree |
| Secret redaction | Eta_ai.api_key redaction tests pass through Eta_redacted; live reach redacts configured env-key values plus sk-/ak-/org- token patterns; latest-result scan passed. | Proven for tested paths |
| Stop conditions honored | eta-stream and eta-schema gaps were filed in their owning packages; tokenizer deferred; eta-http TLS RNG gap fixed in eta-http. | Proven by ADR/journal artifacts |
| Existing named backlog closure with close_reason | Eta-5zo, Eta-yo4, Eta-331, Eta-xgg, Eta-jxz, Eta-jo5, Eta-mw8, Eta-lho, Eta-1gj, and Eta-1yb are closed with close_reason fields in .backlog. | Proven for existing named tasks |
| Track A slice backlog records | Eta-AI-Research, Eta-AI-A1..A5, Eta-AI-Core, Eta-AI-AC0..AC7, and Eta-AI-AP1..AP4 now exist in .backlog. All Track A records are closed with close_reason fields; AP1/AP3 close under the explicit available-account scope. | Proven |
| One live reach probe per provider per release | Anthropic, OpenRouter, Mistral, Groq, DeepSeek, Novita, and Perplexity passed; OpenAI, Kimi Code, Z.ai, and Moonshot reached providers with typed account/product/billing errors; Together and Fireworks skipped due missing accounts. | Proven under available-account scope |

## Remaining Work

No remaining work for the current objective under the available-account scope.

Reopeners:

1. Re-run OpenAI if a funded OPENAI_API_KEY becomes available.
2. Re-run Kimi Code from an allowed coding-agent context if required.
3. Re-run Z.ai or Moonshot if billing/resource state becomes available.
4. Re-run Together or Fireworks if accounts and keys become available.
5. Re-run nix develop -c eta-oxcaml-test-shipped after any further code or manifest edits.

## Current Verdict

Mark the master objective complete under the available-account scope. The code,
audits, ADRs, journal, objective files, and local backlog records agree, and
the remaining unavailable live-provider successes are explicit reopeners rather
than completion blockers.
