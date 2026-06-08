# H-D-Errors Results

Status: PASS.

Command:

    nix develop -c dune exec scratch/eta_http_research/h_d_errors/fixtures.exe

Output:

    PASS all required variants expose low-cardinality fields
    PASS layers distinguish TCP/TLS/ALPN/HTTP/body-decode failures
    PASS retry policy distinguishes decode corruption from protocol abuse
    PASS redaction hides headers, query strings, and bodies in projections
    PASS structured error fits in Eta Cause.t leaf
    PASS H-D1/H-D5/Pool/security outcomes map to class+layer pairs
    h_d_errors fixtures passed

## Verdict

Candidate A, one eta-http payload in the typed failure channel, is accepted for
the eta-http v1 design surface. It covers the Track A request failures and the
Track B malicious-peer outcomes without adding HTTP-specific constructors to
Eta.Cause.

H-Q hardening expanded the taxonomy instead of flattening protocol-security
semantics into Decode_error or Connection_closed. WINDOW_UPDATE accounting maps
to Connection_protocol_violation, PING flood to Ping_rate_exceeded, SETTINGS
churn to Settings_churn_rate_exceeded, response-header churn to
Response_header_change_rate_exceeded, and header normalization failures to
Header_invalid.

The retry-policy consumer is the deciding evidence: transient Decode_error is
retryable if the request body is replayable, while protocol abuse and rate
violations are not retryable.

Default projections redact sensitive headers, redact URL query strings, and
omit bodies. Body capture remains outside this verdict; adding debug snippets
would require a separate opt-in API and evidence.
