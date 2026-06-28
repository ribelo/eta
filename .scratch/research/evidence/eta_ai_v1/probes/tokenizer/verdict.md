# A4 verdict

Status: accepted; tokenizer deferred from eta-ai v1.

Decision:

- eta-ai v1 should not ship a tokenizer.
- eta-ai v1 should not expose byte-count or word-count estimates as token
  estimates.
- eta-ai v1 should preserve provider usage fields after calls.
- A tokenizer can land in v1.x as a separate package slice after choosing FFI
  to tiktoken-rs, a pure OCaml BPE implementation, or another maintained
  source of truth.

Evidence:

- OpenAI, Anthropic, and OpenRouter all expose provider-side usage fields.
- Anthropic explicitly warns usage does not match one-to-one with visible
  request/response content after provider transformations.
- A tiktoken reference measurement for gpt-4o-mini shows byte/4 is close for
  plain English and JSON, but underestimates a small OCaml code prompt by
  42.86 percent. Word-based estimates fail badly for JSON and CJK.

Verification:

    nix develop -c bash .scratch/eta_ai_v1/probes/tokenizer/run.sh

Expected output:

    max_abs_byte4_error=42.86%
    byte_count_estimate=failed
    selected_v1_shape=provider_usage_only
    tokenizer_probe=ok

Disproof signature outcome:

- Triggered for byte-count token estimation. It is observably wrong for common
  prompt-budgeting cases such as code.
- Not triggered for deferring tokenizer support entirely. eta-ai v1 can still
  run calls and report provider usage after responses.

Phase A-C implication:

- Do not add a preflight token-budget API in eta-ai v1.
- Do keep usage fields in response metadata.
- If callers need preflight budgeting in v1, expose a capability hook so the
  application can supply its own tokenizer without eta-ai owning one.
