# H-S3-Reach Verdict

Verdict: Option 2 stands with caveats.

The corrected reachability matrix tested 13 concrete HTTPS targets across
OTLP/collector, LLM provider, Cloudflare-fronted, and AWS-fronted endpoint
classes. Every tested target accepted a TLS 1.2 handshake under ADR 0002's
narrowed ECDHE-AEAD cipher policy.

No target produced evidence that TLS 1.3 is required for eta-http v1's intended
endpoint classes.

## Caveats

- Azure OpenAI exact coverage remains unproven because Azure OpenAI data-plane
  hosts are tenant/resource-specific. The lab used models.inference.ai.azure.com
  as the concrete public Azure AI endpoint.
- The OpenTelemetry demo collector is compose-internal and no public collector
  DNS endpoint was found. The lab used opentelemetry.io as the public reference
  host, which is reachability evidence for the reference site, not collector
  ingest proof.

## Consequence

Proceed to H-S3-Enforce. Hardening the ADR 0002 policy is not wasted work given
the current evidence, but future tenant-specific Azure OpenAI or public OTel demo
collector failures must reopen the TLS substrate decision.
