---
id: Eta-dgp
title: "P3: TLS revocation gap; stale README; empty h2/frame.ml skeleton"
status: open
priority: 3
issue_type: bug
created_at: 2026-05-24T12:52:41.211Z
created_by: backlog
updated_at: 2026-05-24T12:52:47.973Z
dependencies:
  - issue_id: Eta-dgp
    depends_on_id: Eta-0xe
    type: parent-child
    created_at: 2026-05-24T12:52:47.973Z
    created_by: backlog
---

# P3: TLS revocation gap; stale README; empty h2/frame.ml skeleton

## description

Three maintainability/defensive gaps:

1. TLS revocation: packages/eta-http/tls/config.ml locks TLS version/ciphers and uses X509 authenticator, but no OCSP, CRL, stapling, or revocation policy surface. Document as unsupported/delegated in v1.

2. README status stale: packages/eta-http/README.md says S1 current, chunked/gzip/h2/body work pending, but probes show S3 gzip, h2 dispatch, h2 body streams, retry, observability have landed.

3. h2/frame.ml + .mli are empty public skeletons saying 'Thin HTTP/2 frame adapter skeleton' — creates confusion and dead API surface.

Location: packages/eta-http/tls/config.ml; packages/eta-http/README.md; packages/eta-http/h2/frame.ml

## design

1. Document revocation as unsupported/delegated in v1. 2. Update README status and limits to match current package. 3. Remove empty frame module or fill with frame envelope helpers.

## acceptance criteria

Revocation posture documented. README matches shipped code. Empty frame skeleton removed or filled.
