# PRD: HTTP JS Fetch Client and Transport-Neutral Package Split

## Problem Statement

Eta users can make HTTP requests from native OCaml through the Eio adapter, but
they cannot use Eta HTTP from JavaScript targets.

The current HTTP package also mixes shared contracts with native implementation
substrate. A JavaScript user who only needs request/response types and a Fetch
client should not install OpenSSL C stubs, Eio transport code, HTTP/1 or HTTP/2
wire helpers, or WebSocket runtime code.

AI provider packages must run over any `Eta_http.Client.t`. They should not
pull native transports unless the package is explicitly a native transport
adapter.

## Solution

Make `eta_http` the minimal backend-neutral HTTP contract, then add a
js_of_ocaml-only Fetch adapter named `eta_http_js`.

The Fetch adapter supports simple API querying well: absolute URL requests,
fixed request bodies, streamed response bodies, visible host redirects,
cancellation through AbortController, and normal response status inspection.

Concrete wire and transport code moves to named sibling packages. Provider
packages depend only on the shared HTTP contract. Native and JavaScript
transport adapters are selected explicitly by applications.

## User Stories

1. As a JavaScript Eta application author, I want to create an HTTP client over
   host Fetch, so that I can call JSON APIs from js_of_ocaml programs.
2. As a browser Eta application author, I want the adapter to use
   `globalThis.fetch`, so that it works with the browser's HTTP stack.
3. As a Worker Eta application author, I want the same Fetch adapter, so that I
   can call APIs from edge runtimes without Eio.
4. As a Bun or Deno Eta application author, I want the same Fetch adapter, so
   that server-side JavaScript HTTP uses the runtime's Fetch implementation.
5. As a modern Node Eta application author, I want the Fetch adapter to work
   with Node's built-in Fetch, so that I do not need a polyfill package.
6. As an Eta library author, I want one `Eta_http.Client.t` contract, so that
   my code works with native and JavaScript adapters.
7. As an Eta user, I want missing Fetch to fail loudly, so that host support
   problems are found immediately.
8. As an Eta user, I want redirects returned as responses, so that Eta does not
   silently rewrite methods or follow cross-origin redirects.
9. As an Eta user, I want HTTP 4xx and 5xx responses returned normally, so that
   provider packages can decode error bodies.
10. As an Eta user, I want request and response bodies handled as bytes, so
    that Eta does not corrupt binary payloads or provider JSON.
11. As an Eta user, I want streamed Fetch responses exposed as
    `Eta_http.Body.Stream.t`, so that SSE and large responses do not require
    full buffering.
12. As an Eta user, I want request cancellation to abort Fetch, so that
    cancelled Eta effects release host resources.
13. As an Eta user, I want response body discard to cancel the Fetch reader
    when possible, so that unread response bodies do not keep work alive.
14. As an Eta user, I want one-shot streaming uploads rejected, so that the
    adapter does not pretend to support host-dependent upload streaming.
15. As an Eta user, I want rewindable request streams collected within a
    separate buffered upload cap, so that replayable request bodies remain
    correct without mixing upload and response budgets.
16. As an Eta user, I want forced HTTP/1.1 or HTTP/2 selection rejected under
    Fetch, so that Eta does not claim protocol control Fetch does not expose.
17. As an Eta user, I want `ca_file` rejected under Fetch, so that custom trust
    store support is not silently ignored.
18. As an Eta user, I want forbidden headers and CORS failures surfaced as
    typed errors, so that host policy is visible.
19. As an Eta user, I want response headers to match Fetch-visible headers, so
    that CORS-hidden headers are not invented.
20. As an Eta user, I want absolute URL requirements, so that behavior is
    deterministic across browser, Worker, Node, Bun, and Deno hosts.
21. As an Eta user, I want no ambient cookie jar, so that HTTP credentials are
    explicit and not silently persisted by Eta.
22. As an Eta user, I want GET and HEAD bodies rejected before Fetch, so that
    invalid requests fail clearly.
23. As an Eta user, I want Fetch-forbidden request headers rejected before
    Fetch, so that Eta does not silently drop or host-dependently accept them.
24. As an Eta user, I want response trailers to be empty under Fetch, so that
    the adapter only exposes portable host data.
25. As an Eta user, I want WebSocket support outside the Fetch adapter, so that
    WebSocket lifecycle and backpressure are modeled correctly.
26. As an Eta user, I want client stats to be unsupported when the adapter has
    no real stats, so that I am not shown fake socket or pool data.
27. As a native Eta user, I want Eio HTTP behavior preserved through explicit
    protocol and TLS packages, so that native HTTP remains capable.
28. As a native Eta user, I want OpenSSL code installed only with native TLS
    packages, so that non-native clients do not inherit C-stub dependencies.
29. As an HTTP protocol contributor, I want HTTP/1 helpers in an HTTP/1
    package, so that wire machinery is imported intentionally.
30. As an HTTP protocol contributor, I want HTTP/2 helpers in the HTTP/2
    package, so that minimal HTTP clients do not install HTTP/2 state machines.
31. As a service author, I want backend-neutral server handler types to stay in
    `eta_http`, so that routers and future server adapters share one handler
    contract.
32. As an `eta_http_service` user, I want routing and middleware to keep using
    backend-neutral handlers, so that they do not depend on Eio or Fetch.
33. As an AI provider package author, I want provider packages to depend only
    on `eta_http`, so that the same provider works with native and JS clients.
34. As an OpenAI package user, I want normal OpenAI endpoints to work with any
    `Eta_http.Client.t`, so that Fetch can call chat, responses, embeddings,
    images, speech, and transcription where the host supports the payload.
35. As an OpenAI Realtime user, I want WebSocket connection code in a named
    backend package, so that Realtime does not force Eio on ordinary OpenAI
    users.
36. As an observability user, I want request counts in tracer/meter data, not
    fake pool stats, so that telemetry names what was actually measured.
37. As a package maintainer, I want dependency audits to prove the boundary, so
    that native and JS dependencies do not leak back into shared packages.
38. As a test maintainer, I want Node Fetch integration tests with a local
    server, so that Fetch behavior is proven without live Internet.
39. As a test maintainer, I want Node-specific APIs only in tests, so that the
    adapter remains browser/Worker-compatible.
40. As a future adapter author, I want clear package names for backend-specific
    code, so that new Deno, Worker, or WebSocket adapters do not blur
    contracts.

## Implementation Decisions

- `eta_http` becomes the minimal backend-neutral HTTP contract.
- `eta_http` keeps client contracts, response bodies, request bodies, typed
  errors, retry, trace context, observability helpers, core URL/header/method
  values, and backend-neutral server handler contracts.
- `eta_http` removes nested HTTP/1, HTTP/2, Hpack, WebSocket, and OpenSSL
  implementation aliases.
- HTTP/1 parser/writer helpers move to `eta_http_h1`.
- HTTP/2 helpers live in `eta_http_h2`; any remaining wrappers currently
  exposed through `eta_http` move there.
- OpenSSL TLS code moves to `eta_http_tls_openssl`.
- WebSocket codec and handshake helpers move to `eta_http_ws`.
- `eta_http_eio` depends on the protocol, TLS, and WebSocket packages it uses.
- `eta_http_js` is a js_of_ocaml-only package using host Fetch.
- `eta_http_js` exposes a runtime service and a direct client constructor.
- `Eta_js.Runtime.create` does not attach HTTP by default.
- `eta_http_js` requires `globalThis.fetch`; it does not provide a polyfill.
- `AbortController` is required; missing Fetch or AbortController fails with
  `Host_api_unavailable`.
- `eta_http_js` does not expose Fetch `mode` or `no-cors`.
- `eta_http_js` sets `mode = "cors"` internally.
- Opaque Fetch responses fail loudly as host policy errors.
- `eta_http_js` sets `referrerPolicy = "no-referrer"` internally and exposes no
  referrer option in v1.
- `eta_http_js` sets `cache = "no-store"` internally and exposes no Fetch cache
  option in v1.
- `eta_http_js` uses host Fetch and does not promise direct network access in
  browsers; service worker mediation is application-owned.
- `eta_http_js` supports only automatic host protocol negotiation.
- Forced HTTP/1.1 and HTTP/2 fail as unsupported under Fetch.
- `ca_file` fails as unsupported under Fetch.
- Fetch host failures use a small shared taxonomy:
  `Unsupported_adapter_feature`, `Host_api_unavailable`, `Host_api_error`, and
  `Host_policy_error` when the host exposes a policy cause.
- Opaque Fetch rejections are not mapped to DNS, TCP, TLS, or certificate
  failures unless the host exposes that exact cause.
- Request bodies support empty, fixed, and bounded rewindable bodies.
- `Rewindable_stream` request bodies are bounded by
  `max_buffered_request_body_bytes`, distinct from the response body cap.
- `max_buffered_request_body_bytes` defaults to `1_048_576` bytes.
- `Eta_http_js.Client.make` accepts response and upload caps.
- `Eta_http_js.runtime_service` accepts `?max_buffered_request_body_bytes`;
  response caps for runtime clients still come from
  `Eta_http.Client.make_runtime`.
- Upload cap failures use `Request_body_too_large { limit; length }`, not a
  response body decode error.
- Fixed byte-list request bodies are accepted as caller-materialized data.
- One-shot request streams are rejected.
- Invalid method tokens fail before Fetch.
- Fetch-forbidden methods `CONNECT`, `TRACE`, and `TRACK` fail before Fetch.
- Custom method casing is not normalized.
- Response bodies stream through Fetch `ReadableStream` readers when possible.
- Array-buffer fallback is allowed only when the host lacks readable streams,
  and it must respect the configured response cap.
- Fetch body read, cancel, and array-buffer failures map to `Host_api_error`.
- Response body cap failures cancel the Fetch reader where possible.
- Fetch response bytes and headers are exposed as Fetch presents them.
- Eta does not add decompression, normalize `Content-Encoding` or
  `Content-Length`, or validate body length against `Content-Length` under
  Fetch.
- Redirects are manual.
- Visible 3xx redirects return normal responses.
- Opaque redirect responses fail loudly as host errors; Fetch status `0` is not
  a valid `Eta_http.Response.status`.
- HTTP status codes are returned as responses.
- Eta cancellation aborts Fetch.
- Response discard cancels the reader when supported.
- Headers are passed through without silent drops.
- Fetch-forbidden request headers fail before Fetch, including
  `Content-Length`.
- Duplicate request header names fail before Fetch after case-insensitive
  normalization.
- Duplicate response header lines are not reconstructed from Fetch headers.
- Host-specific response header extensions such as server-only `Set-Cookie`
  helpers are not used.
- Host header/CORS failures become typed Eta HTTP failures.
- Response headers are host-visible headers only.
- URLs must be absolute `http` or `https`.
- Bodies are raw bytes.
- Response trailers are empty for Fetch.
- WebSocket is out of scope for the Fetch adapter.
- Client stats become `stats option`; Fetch returns `None`.
- Metrics and traces are the place for request activity observations.
- Retry time uses the Eta runtime clock rather than Unix time.
- AI provider packages are transport-neutral.
- OpenAI Realtime connection code moves to a backend-specific package.
- The OpenAI Realtime native connection package is
  `eta_ai_openai_realtime_eio`.
- Transport-specific AI convenience packages must be named for their backend.

## Testing Decisions

- Test external behavior through the highest seam: `Eta_http.Client.t`.
- Prefer runtime-service tests where possible, because that is how
  applications attach HTTP to Eta runtimes.
- Keep protocol helper tests in protocol packages after the split.
- Keep Eio transport tests in native transport test directories.
- Add a JS Fetch integration test executable compiled with js_of_ocaml CPS
  effects and run under Node.
- The JS integration test starts a local Node HTTP server from test harness
  code.
- The JS gate verifies GET status, headers, and body bytes.
- The JS gate verifies fixed POST body round-trip.
- The JS gate verifies bounded rewindable upload success and upload cap
  failure.
- The JS gate verifies manual redirects are not followed when the host exposes a
  visible 3xx response.
- The JS gate verifies Eta cancellation aborts a hanging Fetch request.
- The JS gate verifies forced protocol selection fails loudly.
- The JS gate verifies missing unsupported options fail loudly.
- The JS gate verifies missing `fetch` and missing `AbortController` fail
  loudly.
- The JS gate verifies forbidden methods and duplicate request headers fail
  before Fetch.
- The JS gate verifies fixed Fetch options through a fake Fetch seam:
  `mode = "cors"`, `redirect = "manual"`, `credentials = "omit"`,
  `referrerPolicy = "no-referrer"`, and `cache = "no-store"`.
- The JS gate verifies streamed response reading when `getReader` exists.
- The JS gate verifies host read errors become `Host_api_error`.
- The JS gate verifies response body discard closes/cancels the Fetch reader
  where the host exposes that behavior.
- The JS gate does not call live Internet services.
- Browser CORS tests are out of the normal gate.
- Node-specific APIs are allowed in the test harness, not the adapter.
- Existing AI provider tests should continue to use custom `Eta_http.Client.t`
  clients for codec and request behavior.
- Add package-boundary tests proving `eta_ai_openai` does not depend on Eio or
  `eta_http_eio`; only `eta_ai_openai_realtime_eio` may do so.
- Add or update package-boundary audits to reject `eta_http_eio`, Eio, and JS
  runtime dependencies from transport-neutral provider packages.
- Add or update package-boundary audits to reject OpenSSL and concrete protocol
  aliases from minimal `eta_http`.

## Out of Scope

- HTTP serving on JavaScript runtimes.
- WebSocket support in `eta_http_js`.
- Upload streaming over Fetch.
- Automatic redirect following.
- Cookie jar support.
- Ambient credential support by default.
- Custom Fetch referrer policy.
- Custom Fetch cache mode.
- Bypassing service workers or other host Fetch mediation.
- Server-side Fetch extensions for forbidden browser request headers.
- Duplicate request header lines under Fetch.
- Fetch-forbidden methods: `CONNECT`, `TRACE`, and `TRACK`.
- Host-specific response header extensions such as server-only `Set-Cookie`
  helpers.
- Browser-relative URL resolution.
- Per-request custom CA files in Fetch.
- Forcing HTTP/1.1 or HTTP/2 over Fetch.
- Fetch `mode` customization, including `no-cors`.
- Response trailers over Fetch until hosts expose a portable trailers API.
- Live Internet tests in the normal gate.
- Browser CORS automation in the normal gate.
- Polyfilling Fetch for old or custom hosts.
- Melange, ReScript, or non-js_of_ocaml JavaScript backends.

## Further Notes

This is one milestone, not a staged cleanup. The HTTP package split, AI
transport-neutral cleanup, and Fetch adapter land together because the adapter
is only correct if the shared contracts are genuinely backend-neutral.

The work intentionally accepts breaking changes. The project does not carry
compatibility shims for stale paths.

The Fetch adapter proves simple API querying. It does not pretend to be a
wire-level HTTP implementation.
