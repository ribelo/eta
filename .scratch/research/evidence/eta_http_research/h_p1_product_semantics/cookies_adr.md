# ADR: Cookie Semantics

Status: Accepted for eta-http v1.

## Decision

eta-http v1 has no cookie jar. Cookies are explicit HTTP headers supplied and
consumed by the caller.

The client does not:

- persist Set-Cookie;
- attach Cookie on later requests;
- enforce domain, path, SameSite, Secure, HttpOnly, or expiry rules;
- merge cookie state across requests or redirects.

## Evidence

There is no cookie module in packages/eta-http. The request model exposes
headers as caller-owned data, and the header/redaction modules treat Cookie and
Set-Cookie as ordinary sensitive headers for diagnostics.

## Consequences

Applications that need browser-like cookie behavior must provide it outside
eta-http. This keeps eta-http on the library boundary: applications own state;
eta-http owns effect description and protocol interpretation.
