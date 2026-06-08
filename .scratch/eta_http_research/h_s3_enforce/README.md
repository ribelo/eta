# H-S3-Enforce

Phase 2 enforcement fixture for ADR 0002.

The lab adds one internal construction chokepoint:

    H_s3_enforce_policy.Default_config_builder.default_client

The helper is intentionally small. It does not expose version or cipher
parameters. Callers may only provide the authenticator, peer identity/IP, and
ALPN list.

Run:

    nix develop -c dune exec scratch/eta_http_research/h_s3_enforce/invariants.exe
    nix develop -c bash scratch/eta_http_research/h_s3_enforce/run_negative_compile.sh

The positive fixture directly inspects the produced Tls.Config record through
Tls.Config.of_client. The negative fixtures prove attempts to pass TLS 1.3 or
DHE_RSA overrides through the helper fail to compile because those labels are
not part of the helper's surface.

When eta-http v1 lands, this helper shape should migrate with the public
eta-http TLS configuration API.
