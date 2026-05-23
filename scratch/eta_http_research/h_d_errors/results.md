# H-D-Errors Results

Status: PASS.

Command:

    nix develop -c dune exec scratch/eta_http_research/h_d_errors/fixtures.exe

Output:

    PASS all required variants expose low-cardinality fields
    PASS layers distinguish TCP/TLS/ALPN/HTTP/body-decode failures
    PASS redaction hides headers, query strings, and bodies in projections
    PASS structured error fits in Eta Cause.t leaf
    PASS H-D1/H-D5/Pool/security outcomes map to class+layer pairs
    h_d_errors fixtures passed

## Verdict

Candidate A, one eta-http payload in the typed failure channel, is accepted for
the eta-http v1 design surface. It covers the Track A request failures and the
Track B malicious-peer outcomes without adding HTTP-specific constructors to
Eta.Cause.

Default projections redact sensitive headers, redact URL query strings, and
omit bodies. Body capture remains outside this verdict; adding debug snippets
would require a separate opt-in API and evidence.
