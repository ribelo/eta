# ADR 0001: HTTP JS Fetch Adapter and Transport Boundaries

Status: accepted.

## Context

Eta currently has an HTTP surface that works for native OCaml through the Eio
adapter. Eta also has a js_of_ocaml runtime backend, but no JavaScript HTTP
adapter.

The current HTTP package boundary is too wide for JavaScript. The shared
`eta_http` package exposes backend-neutral contracts, but it also owns concrete
OpenSSL C stubs, HTTP/1 and HTTP/2 helper aliases, and WebSocket codec helpers
that pull native substrate into code that should compile for js_of_ocaml.

The desired JavaScript target is client HTTP over host Fetch. Browser, Worker,
Bun, Deno, and modern Node runtimes expose Fetch-compatible outbound HTTP. They
do not expose a single portable HTTP server listener API.

Eta's package policy is install-only-what-you-use. A package that only builds
requests, decodes responses, or accepts an `Eta_http.Client.t` must not force a
native transport, JS runtime, OpenSSL, or Eio dependency.

## Decision

Build JavaScript HTTP as a Fetch-backed client adapter named `eta_http_js` with
top-level module `Eta_http_js`.

Before adding the adapter, split the HTTP and AI package graph so the shared
contracts are actually backend-neutral.

### HTTP Package Boundaries

`eta_http` becomes the minimal backend-neutral HTTP contract:

- client request, response, error, body, retry, runtime-service, trace-context,
  and observability contracts;
- core URL, header, method, status, version, and span values;
- backend-neutral server request, response, handler, config, validation, and
  error contracts;
- backend-neutral TLS policy/config data only.

`eta_http` must not expose or depend on concrete wire protocol adapters,
OpenSSL, WebSocket host randomness, Eio, js_of_ocaml, or runtime-specific I/O.

Move concrete protocol and transport surfaces into sibling packages:

- `eta_http_h1`: HTTP/1 parser, request writer, request body framing, response
  writer, and request parser helpers.
- `eta_http_h2`: existing HTTP/2 protocol package. Move any remaining shared
  H2 wrappers, config, security, and compatibility aliases there.
- `eta_http_tls_openssl`: native OpenSSL state machine, C stubs, memory BIOs,
  sessions, CA-file loading, and concrete client/server context creation.
- `eta_http_ws`: RFC 6455 codec and handshake helpers. Handshake helpers must
  not hard-code OpenSSL randomness or SHA-1 when they need to support more than
  native OCaml.
- `eta_http_eio`: native Eio HTTP adapter. It depends on the protocol/TLS/WS
  packages it uses and owns DNS, TCP, TLS, ALPN, pooling, serving loops, HTTP/2
  connection ownership, and native WebSocket I/O.
- `eta_http_js`: js_of_ocaml Fetch client adapter.

Delete `Eta_http.H1`, `Eta_http.H2`, `Eta_http.Hpack`, and
`Eta_http.Tls.OpenSSL` from the minimal `Eta_http` entry point. Callers that
need wire helpers must depend on the wire-helper packages directly.

Keep `Eta_http.Server` in `eta_http`. It is a pure handler contract, not a
server runtime. Future native or JavaScript serving adapters can target the same
handler type.

Keep gzip body transducers in `eta_http` only if their dependencies compile
cleanly to js_of_ocaml. If they block the JS-compatible core, move them to a
small optional compression package instead of making `eta_http_js` own
compression.

### Fetch Adapter Contract

`eta_http_js` is client-only. It provides outbound HTTP over
`globalThis.fetch`. It does not provide HTTP serving.

`eta_http_js` requires a native `globalThis.fetch` at runtime. It does not
install or embed a polyfill. Missing Fetch is a loud typed failure.

The adapter is js_of_ocaml-only for now. It depends on the existing JS Eta
runtime bridge and uses js_of_ocaml CPS effects. It does not claim support for
Melange, ReScript, or another OCaml-to-JS backend.

The public surface is:

- a runtime service for `Eta_http.Client.make_runtime`;
- a direct `Eta_http_js.Client.make` convenience constructor implemented as a
  thin `Eta_http.Client.make_custom` wrapper.

`Eta_js.Runtime.create` must not attach the Fetch HTTP service by default.
Applications attach `Eta_http_js.runtime_service ()` explicitly.

The direct JS client constructor stays small. It accepts only options that do
not punch through host policy. The supported options are Eta-owned safety
limits: the response body cap and the buffered upload cap for collected
`Rewindable_stream` request bodies. There is no stringly passthrough for Fetch
options.

Both caps default to `Eta_http.Body.Stream.default_max_bytes`, currently
`1_048_576` bytes. `Eta_http_js.Client.make` accepts both caps. The runtime
service accepts `?max_buffered_request_body_bytes`; `max_response_body_bytes`
continues to come from `Eta_http.Client.make_runtime` through shared runtime
options.

The adapter does not expose Fetch `mode`. It sets `mode = "cors"` and does not
offer `no-cors`, because opaque responses do not expose an HTTP status,
headers, or usable body. If the host returns an opaque response anyway, the
adapter fails loudly with a host policy error.

### Fetch Behavior

Protocol selection is opaque in Fetch. `Auto` is the only supported protocol
mode. Forced `H1` or `H2` returns a typed protocol violation.

`~ca_file` is unsupported in Fetch. A request made with this option returns a
typed protocol violation instead of silently ignoring the option.

Fetch host failures get a small shared error taxonomy instead of being mapped to
native transport facts that Fetch did not expose. Add only:

- `Unsupported_adapter_feature { adapter; feature; message }`;
- `Host_api_unavailable { api; message }`;
- `Host_api_error { api; message }`;
- `Host_policy_error { policy; message }`, only when the host exposes enough to
  distinguish policy from a generic API failure.

A browser `TypeError` is not reported as DNS, TCP, TLS, or certificate failure
unless the host API exposes that exact cause. Eta cancellation remains runtime
cancellation and aborts Fetch through `AbortController`; it is not converted
into an HTTP client error.

`AbortController` is a required host API because cancellation is part of the
adapter contract. Missing `globalThis.fetch` or `AbortController` fails with
`Host_api_unavailable`. Missing readable-stream support is not fatal if
`arrayBuffer()` is available for the bounded fallback path.

Request methods are validated before Fetch. Invalid method tokens fail with a
typed header/protocol error. Fetch-forbidden methods, case-insensitively
`CONNECT`, `TRACE`, and `TRACK`, fail before Fetch with a host policy error.
The adapter does not normalize custom method casing.

Request bodies support:

- `Empty`;
- `Fixed`;
- `Rewindable_stream`, collected eagerly within a separate configured buffered
  upload cap.

The buffered upload cap is distinct from the response body cap. Fixed byte-list
bodies are already caller-materialized and do not consume the adapter's
collection budget. Adapter-collected streams fail before reading past the
configured upload cap. Add a client error kind
`Request_body_too_large { limit; length }` for this failure; do not report it
as a response body decode failure.

One-shot `Stream` request bodies are rejected for the first adapter. Fetch
upload streaming differs across hosts, and Node requires special `duplex`
handling.

Response bodies are exposed as pull-based `Eta_http.Body.Stream.t` when
`response.body.getReader` is available. If a host lacks readable streams, the
adapter may fall back to bounded `arrayBuffer()` materialization.

Failures from `ReadableStreamDefaultReader.read`, `reader.cancel`, or
`arrayBuffer()` map to `Host_api_error` with the host API named in the error.
If response body reading exceeds `max_response_body_bytes`, the adapter cancels
the Fetch reader where possible and fails with the response body size error.

All bodies are raw bytes. The adapter does not infer text, normalize newlines,
or transcode.

Fetch may expose host-processed response bytes rather than wire bytes,
especially when the host applies content codings. The adapter exposes the body
bytes and headers that Fetch exposes. It does not add Eta-level decompression,
does not normalize `Content-Encoding` or `Content-Length`, and does not validate
the received body length against `Content-Length` under Fetch. The configured
response body cap applies to the bytes read from Fetch.

HTTP statuses, including 3xx, 4xx, and 5xx, return normal
`Eta_http.Response.t` values. Provider packages and callers inspect status and
decode response bodies themselves.

Redirects are manual. The adapter sets Fetch redirect handling so redirects are
not silently followed. If the host exposes a real 3xx response, Eta returns that
normal response. If the host returns an opaque redirect response, such as a
browser `opaqueredirect` with status `0`, empty headers, and no body, the
adapter fails loudly with a host error. `Eta_http.Response.status` remains an
HTTP status and must not carry Fetch status `0`.

Eta cancellation aborts the Fetch request through `AbortController`. Response
body discard/release cancels the reader where the host supports it.

The adapter does not add hidden timeouts. Callers compose Eta timeouts around
requests. Cancellation is still bridged to Fetch abort.

Headers are passed through without silent drops. The adapter validates Eta
headers as usual and pre-rejects Fetch-forbidden request headers with a typed
host policy error, even on server-side Fetch hosts that might accept more. The
portable Fetch contract is the browser contract. Forbidden names include
`Accept-Charset`, `Accept-Encoding`, `Access-Control-Request-Headers`,
`Access-Control-Request-Method`, `Connection`, `Content-Length`, `Cookie`,
`Cookie2`, `Date`, `DNT`, `Expect`, `Host`, `Keep-Alive`, `Origin`, `Referer`,
`Set-Cookie`, `TE`, `Trailer`, `Transfer-Encoding`, `Upgrade`, `Via`, and names
starting with `proxy-` or `sec-`. If CORS blocks the operation, the adapter maps
the host failure to a typed Eta HTTP error.

The adapter also rejects duplicate request header names after case-insensitive
normalization. Fetch can combine, normalize, or hide duplicate headers, which
would make Eta's header list misleading. Callers that want a comma-list header
must provide a single combined value themselves.

Response headers are exactly the headers exposed by Fetch. Browser CORS-hidden
headers are absent and are not treated as Eta errors. The adapter does not use
host-specific response-header extensions such as server-only `Set-Cookie`
helpers and does not try to reconstruct duplicate response header lines.

The adapter accepts only absolute `http` and `https` URLs. Browser-relative
URLs must be resolved before constructing an `Eta_http.Request.t`.

Ambient browser credentials and cookies are not sent by default. The Fetch
adapter must make the no-cookie policy real, for example with
`credentials = "omit"`. Eta has no cookie jar; callers that need credentials
need a future explicit adapter option or a host-permitted explicit header.

The adapter sets `referrerPolicy = "no-referrer"` and does not expose a
referrer option in the first adapter. Browser document context must not leak
through Eta HTTP unless a future explicit option is designed for it.

The adapter sets `cache = "no-store"` and does not expose a Fetch cache option
in the first adapter. Eta HTTP should not read from or update ambient host HTTP
cache state. Callers may still send explicit HTTP cache headers.

The adapter does not promise direct network access in browser hosts. It uses
host Fetch with Eta-owned options, but service workers and equivalent host
mediation remain part of the application environment. Applications that install
or run under such mediation own its consequences.

`GET` and `HEAD` requests with bodies fail before calling Fetch.

The adapter does not synthesize or correct `Content-Length`. Under Fetch,
`Content-Length` is a forbidden request header, so caller-supplied
`Content-Length` fails before Fetch. Fetch owns framing.

Response trailers are empty in the first Fetch adapter. Fetch does not expose a
portable trailers API across the target hosts.

WebSocket is out of scope for `eta_http_js`. A future JS WebSocket adapter must
be separate because host WebSocket APIs have different lifecycle, backpressure,
close, and binary-frame semantics from Fetch.

### Client Stats

Do not fake connection stats for Fetch.

Change the shared client contract so adapter stats can be unavailable. Eio can
return `Some` real pool/protocol stats. Fetch returns `None`. Request counts
belong in observability spans/meters, not in socket-pool fields.

### AI Provider Boundaries

AI provider packages are transport-neutral.

`eta_ai`, `eta_ai_anthropic`, `eta_ai_openai`,
`eta_ai_openai_compat`, `eta_ai_openrouter`, and codec packages may depend on
`eta_http`. They must not depend on `eta_http_eio`, `eta_http_js`, Eio, or JS
runtime packages.

OpenAI Realtime connection code moves out of `eta_ai_openai` into
`eta_ai_openai_realtime_eio`. Pure Realtime session JSON, client-secret request
construction, event encoding, and event decoding can stay in `eta_ai_openai`
because they are transport-neutral.

Backend-specific AI convenience packages must be named for their concrete
transport.

## Alternatives Considered

- Add conditional stubs or `enabled_if` branches inside `eta_http`. Rejected
  because it hides native-only code instead of expressing the package boundary.
- Make `eta_http_js` duplicate the request/response/error model. Rejected
  because providers and OTel should work against one `Eta_http.Client.t`
  contract.
- Map opaque Fetch rejections to native-looking DNS, TCP, TLS, or certificate
  failures. Rejected because Fetch does not reliably expose those causes.
- Keep `Eta_http.H1`, `Eta_http.H2`, and `Eta_http.Tls.OpenSSL` as aliases.
  Rejected because aliases would force minimal `eta_http` to depend on
  implementation packages.
- Buffer all Fetch responses eagerly. Rejected because the public response
  model is streaming and provider SSE needs incremental reads.
- Fake Fetch stats with zeroes or request counters. Rejected because the field
  names describe connection-pool facts Fetch does not expose.
- Include WebSocket in the Fetch adapter. Rejected because Fetch and WebSocket
  are separate host APIs with different semantics.
- Make provider packages pull default transports. Rejected because provider
  packages should be request/codec packages, not runtime owners.

## Consequences

Positive:

- `eta_http` becomes a real backend-neutral contract.
- JavaScript applications can use the same `Eta_http.Client.t` shape as native
  applications.
- Provider packages can run over native Eio or JS Fetch clients without
  package-level transport coupling.
- Concrete protocol and transport dependencies are installed only when needed.

Negative:

- This is a breaking package/API split.
- Current callers using nested `Eta_http.H1`, `Eta_http.H2`,
  `Eta_http.Hpack`, `Eta_http.Ws`, or `Eta_http.Tls.OpenSSL` must import the
  new sibling packages.
- Native Eio packages must be rewired to depend on the new protocol and TLS
  packages.
- `Eta_http.Client.stats` callers must handle unsupported stats.

Risks:

- Some current shared dependencies, especially compression dependencies, may
  still fail under js_of_ocaml. If so, they must be split instead of hidden.
- Fetch behavior varies by host. The adapter boundary is the host-visible
  Fetch behavior, not a full wire-level HTTP implementation.
- Browser CORS can hide response headers or reject requests. Eta exposes that
  host policy; it does not bypass it.

## Rollout

1. Split `eta_http` so it contains only backend-neutral contracts.
2. Move HTTP/1 helpers, remaining HTTP/2 aliases/config, OpenSSL TLS, and
   WebSocket codec surfaces into sibling packages.
3. Rewire `eta_http_eio` to depend on the sibling packages directly.
4. Change client stats to represent unsupported stats.
5. Remove concrete transport dependencies from AI provider packages. Move
   OpenAI Realtime native connection code into a backend-specific package.
6. Add `eta_http_js` as a js_of_ocaml Fetch client adapter.
7. Add Node-based js_of_ocaml integration tests for the Fetch adapter.
8. Update package docs and dependency audits.

No compatibility shim or fallback path is part of this rollout. Old paths are
deleted and callers are updated.

## Verification

Run the native HTTP and shipped package gates after the split:

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
```

Run the JS adapter tests under Node after adding `eta_http_js`:

```sh
nix develop .#mainline -c dune runtest test/http_js --force
```

Run the HTTP package audit after every boundary move:

```sh
nix develop -c bash lib/http/audit/run.sh
```

## References

- `eta_http` README package-boundary language.
- Existing js_of_ocaml runtime packages: `eta_jsoo`, `eta_js`, and
  `eta_js_stream`.
- Existing AI provider ADRs under the `eta_ai` package family.
