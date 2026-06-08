# H-D-Errors Redaction Policy

Default projections are safe for logs and telemetry.

## Headers

The following request/response header values are replaced with <redacted>:

- Authorization
- Cookie
- Set-Cookie
- X-API-Key

Header matching is case-insensitive. The scratch API models the extension point
as Redaction.t, so an eta-http implementation can add application-specific
names without changing the error payload.

## URLs

Query strings are replaced with ?<redacted>. The path and fragment remain
visible so debugging and span attributes can still distinguish routes without
leaking credentials.

Example:

    https://api.example.test/items?token=secret#frag
    https://api.example.test/items?<redacted>#frag

## Bodies

Bodies are never quoted by default projections. The H-D-Errors verdict keeps
body content out of pretty-print and JSON-style output entirely; body capture
would need a later explicit debug-only API and separate evidence.
