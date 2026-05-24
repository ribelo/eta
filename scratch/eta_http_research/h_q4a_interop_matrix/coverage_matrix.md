# H-Q4a Coverage Matrix

| Scenario | Fixture | eta-http status | Notes |
| --- | --- | --- | --- |
| ALPN h2 negotiation | nginx and Caddy TLS h2 | covered | eta probe uses HTTPS auto client with insecure local authenticator. |
| h2c prior knowledge | Caddy h2c with curl/nghttp2 | not supported by public eta-http client | Public client routes plain HTTP to h1. |
| keep-alive | nginx h1 repeat in one eta client | covered | Probe repeats two requests through one h1 client. |
| redirects | nginx 302 | covered | eta-http returns 302 and does not auto-follow. |
| trailers | nginx add_trailer | covered | eta h1 probe requests `TE: trailers` and observes `X-Trailer: nginx-trailer`. |
| HEAD | nginx HEAD | covered | Body byte count stays zero. |
| 100-Continue | nginx Expect/Continue route | covered | eta-http h1 skips the interim 100 and returns the final 200 response. |
| zero-byte DATA | Caddy h2 empty response | covered | HTTPS h2 response with zero body bytes. |
| mid-body close | nginx slow body with worker kill | covered with caveat | eta-http reports a typed Connection_closed while draining the response body; this is a hard server close, not a handcrafted TCP RST frame. |
| flow-control exhaustion | Caddy h2 100MB body | covered with caveat | The real-server fixture crosses HTTP/2 flow-control windows and drains 100MB; pathological stalled-window behavior remains unit/property-test territory. |
| ALPN downgrade | nginx TLS h1 fallback | covered | eta h1-only probe connects to the TLS listener and receives the h1 response path. |
| early 413 | nginx client_max_body_size | covered | eta sees status 413 during POST. |
| large body 100MB | nginx sparse static file | covered | Probe streams and counts 104857600 bytes. |
| SSE long-lived heartbeat | nginx rate-limited SSE payload | covered with caveat | Probe reads the first chunk from a held-open response and verifies it can return before EOF. |
| server-push rejection | nghttpd push fixture | covered | nghttpd advertises push; eta-http sends SETTINGS_ENABLE_PUSH=0 and receives only the requested response. |
| WebSocket upgrade rejection | nginx and Caddy 426 | covered | Upgrade request returns normal HTTP 426. |
