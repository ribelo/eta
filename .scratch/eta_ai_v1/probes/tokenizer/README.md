# A4 tokenizer triage

Question: should eta-ai v1 ship a tokenizer, use byte-count estimates, or rely
only on provider-side usage?

Run:

    nix develop -c bash scratch/eta_ai_v1/probes/tokenizer/run.sh

The probe uses tiktoken through uv as a disposable reference tool. It is not a
production dependency.

Current result:

    tokenizer_probe=ok
    byte_count_estimate=failed
    selected_v1_shape=provider_usage_only

Decision:

- Do not ship a tokenizer in eta-ai v1.
- Do not expose byte-count output as a token estimate.
- Preserve provider usage fields after calls.
- Tokenizer support can land in v1.x as a separate package slice.
