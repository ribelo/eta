# ADR 0002: HTTP Wire Construction Ownership

Status: accepted.

## Context

AI providers independently implemented multipart/form-data framing and URL query
percent encoding. Both operations contain protocol and security invariants that
must not drift between providers, but neither is AI-specific.

## Decision

`eta_http` owns both shared wire-construction surfaces.

`Eta_http.Multipart` encodes text fields and binary files, rejects disposition
and header injection, deterministically selects a content-derived boundary that
does not collide with any encoded metadata or payload, preserves file bytes, and
returns a typed error or a boundary with a `bytes list` suitable for
`Eta_http.Request.Fixed`. Its public part vocabulary contains only named text
fields and named binary files with filename and content type. It uses a fixed
Eta-owned boundary prefix and rejects an empty part list. Provider adapters map
multipart errors into their own error domains.

`Eta_http.Core.Url` exposes both query-component percent encoding and an optional
field query builder implemented with that encoder. The encoder preserves RFC
3986 unreserved octets, emits spaces as `%20`, and emits every other UTF-8 octet
as uppercase `%HH`. The query builder omits absent values while preserving input
order and repeated names.

OpenAI, OpenRouter-family adapters, and xAI delete their local implementations
and use these HTTP-owned operations. No compatibility aliases remain.

## Rejected

- Put multipart and query helpers in `eta_ai`. Their invariants are HTTP wire
  concerns and already have non-provider utility.
- Parameterize multipart encoding by provider error constructors. That would
  make HTTP framing depend on adapter policy.
- Generate random multipart boundaries. Collision checking supplies framing
  safety; randomness would add a capability dependency and nondeterministic
  tests.
- Return one contiguous multipart buffer. Fixed body chunks preserve caller file
  buffers and avoid unnecessary concatenation.
