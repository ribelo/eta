# ADR: Redirect Semantics

Status: Accepted for eta-http v1.

## Decision

eta-http v1 does not automatically follow HTTP redirects. A response with status
301, 302, 303, 307, or 308 is returned to the caller as an ordinary response.

Callers that want redirect following own the policy:

- which status codes are followed;
- whether 301, 302, or 303 rewrite the method to GET;
- whether request bodies are replayable;
- whether Authorization, Cookie, or other sensitive headers are stripped on
  cross-origin hops;
- maximum redirect count and loop detection.

## Evidence

packages/eta-http/core/status.ml exposes is_redirection as a classifier only.
packages/eta-http/client/retry.mli documents retry policy and has no redirect
following API. `docs/research/evidence/eta_http_v1/probes/observability/s6_observability_probe.md`
explicitly records that v1 redirect support is semantic-convention attribute
derivation, not automatic redirect following.

## Consequences

eta-http never rewrites methods for redirects and never copies sensitive headers
to another origin as part of redirect handling, because it does not perform the
redirect request. Applications that implement redirects must make those choices
at their own boundary.
