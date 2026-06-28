# H-P1 Product Semantics

Question: are eta-http v1 product-level HTTP behaviors explicit enough for
callers to rely on them?

Verdict: PASS for documentation of the current v1 defaults.

Artifacts:

- redirects_adr.md: redirects are caller-owned; eta-http returns 3xx responses.
- cookies_adr.md: cookies are header-explicit; eta-http has no cookie jar.
- trailers_adr.md: response trailers are delivered through Response.trailers.
- head_adr.md: HEAD, 1xx, 204, and 304 responses do not wait for a body.
- early_response_adr.md: early response during upload is a close/error boundary;
  eta-http does not claim Expect: 100-continue or upload-drain semantics.
- pipelining_adr.md: HTTP/1.1 pipelining is out of scope.

Evidence:

- packages/eta-http/core/status.ml exposes redirection classification but the
  client has no redirect-following loop.
- packages/eta-http/client/retry.mli documents retry policy, not redirect
  policy.
- packages/eta-http/body/chunked.ml and packages/eta-http/h1/client.ml deliver
  HTTP/1.1 chunked trailers.
- packages/eta-http/client/client.ml wires HTTP/2 trailing headers into
  Response.trailers.
- packages/eta-http/h1/client.ml and packages/eta-http/client/client.ml suppress
  response bodies for HEAD, 1xx, 204, and 304.
- packages/eta-http/h1/write.ml maps request write failures to typed
  Connection_closed during Http_request.
