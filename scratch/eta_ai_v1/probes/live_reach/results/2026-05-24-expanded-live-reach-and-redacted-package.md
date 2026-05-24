# 2026-05-24 expanded live reach and eta-redacted package

Status: accepted.

Worktree recovery check:

- No sibling worktree, stash, local branch, remote branch, tracked object path,
  or reflog entry contains a standalone eta-redacted package.
- The only surviving redaction commit was `dcc70a8 feat: ship Eta.Redacted
  port`, which added `packages/eta/redacted.{ml,mli}` inside the eta package.

Package correction:

- Added `packages/eta-redacted/` as the standalone `eta-redacted` library.
- Kept `Eta.Redacted` as a compatibility alias over `Eta_redacted`.
- Switched eta-ai API keys and provider auth boundaries to `Eta_redacted`.
- Generated `eta-redacted.opam` and added explicit eta-redacted dependencies to
  eta, eta-ai, and provider package metadata.

Focused verification:

    nix develop -c dune runtest packages/eta-redacted packages/eta packages/eta-ai packages/eta-ai-openai packages/eta-ai-anthropic packages/eta-ai-openai-compat packages/eta-ai-openrouter --force
    exit 0
    eta-redacted: 6 tests run
    eta: 186 tests run
    eta-ai: 20 tests run
    eta-ai-openai: 10 tests run
    eta-ai-anthropic: 10 tests run
    eta-ai-openai-compat: 6 tests run
    eta-ai-openrouter: 8 tests run

Shipped-package gate:

    nix develop -c eta-oxcaml-test-shipped
    exit 0
    eta-redacted: 6 tests run
    eta-schema, ppx_eta, eta-ai, eta-ai providers, eta-stream, eta, eta-otel passed

Expanded AP3 live reach:

    nix develop -c bash scratch/eta_ai_v1/probes/live_reach/run.sh deepseek groq kimi-code novita zai moonshot perplexity
    exit 1
    ok provider=groq model=llama-3.3-70b-versatile output_len=2 finish_reasons=1
    ok provider=deepseek model=deepseek-chat output_len=3 finish_reasons=1
    fail provider=kimi-code model=kimi-for-coding provider=kimi-code status=403 code=none message=Kimi For Coding is currently only available for Coding Agents such as Kimi CLI, Claude Code, Roo Code, Kilo Code, etc.
    ok provider=novita model=deepseek/deepseek-v4-flash output_len=3 finish_reasons=1
    fail provider=zai model=glm-4.5-air provider=zai status=429 code=1113 message=insufficient resources
    fail provider=moonshot model=kimi-k2.6 provider=moonshot status=429 code=none message=Your account <redacted:account> <redacted:api_key> is suspended due to insufficient balance, please recharge your account or check your plan and billing details
    ok provider=perplexity model=sonar output_len=2 finish_reasons=1

Secret scan:

- No exact configured provider key value appears in
  `results/live_reach_latest.txt`.
- No unredacted sk-/ak-/org- token pattern appears in
  `results/live_reach_latest.txt`.

Verdict:

The eta-redacted package boundary is restored. AP3 now has additional live
positive coverage for Novita and Perplexity, while Kimi Code, Z.ai, and
Moonshot are classified as external product/account/billing reopeners.
