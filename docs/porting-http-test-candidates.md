# HTTP Test Porting Candidates — zio-http & Effect-TS → Eta

This document collects HTTP server/client tests from
`.reference/zio-http` and `.reference/effect` that are worth porting to Eta.
The focus is on **behavior Eta already owns or is likely to own soon**:
protocol interpretation, request/response lifecycle, streaming, error mapping,
and server runtime. High-level routing DSL, OpenAPI, cookie jars, and
multipart/form-data parsers are noted only when the underlying primitive is
missing.

How to read the tables:

- **Priority** — value × fit with Eta's current surface.
- **Eta gap** — whether Eta lacks explicit coverage for the behavior.
- **Needs new module** — whether the test requires a public API Eta does not
  have today (router, cookie jar, multipart parser, etc.).
- **Source** — exact file and test name in the reference repo.

---

## zio-http candidates

Repository: `.reference/zio-http` (https://github.com/zio/zio-http, shallow clone).

### High priority

| # | File | Test / behavior | Why it matters | Eta gap | Needs new module |
|---|------|-----------------|----------------|---------|------------------|
| 1 | `zio-http/jvm/src/test/scala/zio/http/KeepAliveSpec.scala` | HTTP/1.1 default keep-alive, `Connection: close`, HTTP/1.0 without keep-alive | Eta H1 tests mostly force close; no explicit default keep-alive or HTTP/1.0 fallback. | Yes | No |
| 2 | `zio-http/jvm/src/test/scala/zio/http/MethodAnyHeadSpec.scala` | `Method.ANY` routes respond to HEAD, discard body, set `Content-Length` | RFC HEAD semantics; Eta has no server-side HEAD body-suppression test. | Yes | No |
| 3 | `zio-http/jvm/src/test/scala/zio/http/ServerSpec.scala` suite `generateHeadRoutesSpec` | HEAD falls back to GET route, explicit HEAD route wins, body discarded | Verifies automatic HEAD handling separate from `Method.ANY`. | Yes | No |
| 4 | `zio-http/jvm/src/test/scala/zio/http/RequestStreamingServerSpec.scala` | Unsafe large content stream, multiple body read returns 500, streaming request proxied to client | Eta has streaming body tests but no large end-to-end server streaming + proxy test. | Partial | No |
| 5 | `zio-http/jvm/src/test/scala/zio/http/ClientStreamingSpec.scala` | Simple GET/POST, streaming echo, random multipart form, failed stream | Full client/server streaming interop. Eta client streaming tests are mock-flow based. | Yes | No |
| 6 | `zio-http/jvm/src/test/scala/zio/http/RequestStreamingConcurrencySpec.scala` | 100×20 concurrent store+fetch with request streaming enabled | Regression for auto-read races under load. Eta has no concurrent streaming load test. | Yes | No |
| 7 | `zio-http/jvm/src/test/scala/zio/http/NettyMaxHeaderLengthSpec.scala` | Oversized request header returns `431 Request Header Fields Too Large` | Eta has header byte limits but no explicit status assertion. | Yes | No |
| 8 | `zio-http/jvm/src/test/scala/zio/http/NettyMaxInitialLineLengthSpec.scala` | Long request target returns `414 Request URI Too Long` | Eta has target validation but no explicit URI-too-long status test. | Yes | No |
| 9 | `zio-http/jvm/src/test/scala/zio/http/ServerErrorLoggingSpec.scala` | Sandbox logs defects/typed failures; does not log `Response` failures, middleware failures, or successes | Eta maps errors to 500/reset but does not assert structured logging behavior. | Yes | Log capture helper |
| 10 | `zio-http/jvm/src/test/scala/zio/http/ClientSpec.scala` | Connection failure to `localhost:1`, broken server sends headers but no body, pool exhaustion with broken server | Adversarial client behavior not covered by Eta's mock tests. | Yes | No |
| 11 | `zio-http/jvm/src/test/scala/zio/http/WebSocketSpec.scala` | Server-side upgrade, channel events, close interruptibility, multiple upgrades, HTTP URL fallback | Eta has WebSocket client only; server-side upgrade path is missing. | Yes | WebSocket server |

### Medium priority

| # | File | Test / behavior | Why it matters | Eta gap | Needs new module |
|---|------|-----------------|----------------|---------|------------------|
| 12 | `zio-http/jvm/src/test/scala/zio/http/ServerSpec.scala` suite `compression` | gzip/deflate request decompression + response compression roundtrip | Eta has `Body.Transducer.gzip_*` but no full server compression negotiation test. | Partial | Compression transducer |
| 13 | `zio-http/jvm/src/test/scala/zio/http/ServerSpec.scala` suite `content-length` | Provided `Content-Length` overwritten for string body, preserved for HEAD, preserved for HEAD with stream body | Subtle content-length semantics. | Yes | No |
| 14 | `zio-http/jvm/src/test/scala/zio/http/ServerSpec.scala` suite `interruption` | Interrupt closes channel without response | Eta has cancellation tests but not this exact server channel behavior. | Partial | No |
| 15 | `zio-http/jvm/src/test/scala/zio/http/ClientHttpsSpec.scala` | HTTPS success, bad request, handshake failure with untrusted cert | Focused client/server HTTPS matrix. | Partial | TLS certs |
| 16 | `zio-http/jvm/src/test/scala/zio/http/ClientConnectionSpec.scala` | Tries a different IP when connection fails | Eta's client has DNS/pool code but no multi-IP fallback test. | Yes | DNS mock |
| 17 | `zio-http/jvm/src/test/scala/zio/http/ServerRuntimeSpec.scala` | Runtime flags/fiber refs propagated, scope finalizers | Relevant if Eta exposes environment hooks. | Partial | Runtime hooks |
| 18 | `zio-http/jvm/src/test/scala/zio/http/ServerStartSpec.scala` | Desired port binding, available port (port 0), shutdown before start | Eta has config validation; lacks start/port binding lifecycle tests. | Yes | No |
| 19 | `zio-http/jvm/src/test/scala/zio/http/ServerSpec.scala` `DynamicAppSpec` echo content large data | Echo 10 KB stream via request body | Complements streaming tests with known size assertion. | Partial | No |

### Lower priority / blocked on new modules

| # | File | Test / behavior | Blocker |
|---|------|-----------------|---------|
| 20 | `zio-http/jvm/src/test/scala/zio/http/ContentTypeSpec.scala` | `Content-Type` from file extension | Media-type/file-extension module |
| 21 | `zio-http/jvm/src/test/scala/zio/http/CookieSpec.scala` | Cookie request/response getters, encode/decode, signature | Cookie module |
| 22 | `zio-http/jvm/src/test/scala/zio/http/FormSpec.scala` | URL-encoded and multipart/form-data encoding/decoding | Form/multipart module |
| 23 | `zio-http/jvm/src/test/scala/zio/http/BoundarySpec.scala` | Boundary parsing from content, RFC 2046 random UUID | Multipart support |
| 24 | `zio-http/jvm/src/test/scala/zio/http/MultipartMixedSpec.scala` | `multipart/mixed` parsing, RFC-1341 sample, nested multipart | Multipart parser |
| 25 | `zio-http/jvm/src/test/scala/zio/http/HandlerSpec.scala` | Handler combinators: `sandbox`, `flatMap`, `orElse`, `race`, `catchSome` | `Handler` abstraction |
| 26 | `zio-http/jvm/src/test/scala/zio/http/RoutesSpec.scala` | Route precedence, nested routes, overlapping routes | Routing DSL |
| 27 | `zio-http/jvm/src/test/scala/zio/http/RouteSpec.scala` | Route prefix, sandbox, error handlers, composable methods | Routing DSL |
| 28 | `zio-http/jvm/src/test/scala/zio/http/HandlerAspectSpec.scala` | HandlerAspect with context/environment elimination | Aspect/middleware DSL |
| 29 | `zio-http/jvm/src/test/scala/zio/http/RoutesMiddlewareSpec.scala` | Middleware combine, `runBefore`/`runAfter`, `when`/`whenZIO` | Middleware DSL |

---

## Effect-TS candidates

Repository: `.reference/effect` (https://github.com/Effect-TS/effect, shallow clone).

### High priority

| # | File | Test / behavior | Why it matters | Eta gap | Needs new module |
|---|------|-----------------|----------------|---------|------------------|
| 1 | `packages/platform/test/Multipart.test.ts` | `"it parses"` — parse a 1 MiB file | Common server requirement; Eta has no multipart parser. | Yes | Multipart parser |
| 2 | `packages/platform-node/test/HttpServer.test.ts` | `"formData"` — file upload round-trip with content-type detection and path preservation | End-to-end multipart server behavior. | Yes | Multipart parser |
| 3 | `packages/platform-node/test/HttpServer.test.ts` | `"formData withMaxFileSize"` / `"formData withMaxFieldSize"` | Per-upload and per-field size limits with 413 mapping. | Yes | Multipart parser + limits |
| 4 | `packages/platform-node/test/HttpServer.test.ts` | `"setCookie"` | Complex `Set-Cookie` attributes (HttpOnly, Secure, SameSite, Partitioned, expires, maxAge) | Yes | Cookie builder |
| 5 | `packages/platform/test/Cookies.test.ts` | `unsafeMakeCookie` validation — invalid name/domain/path/maxAge rejection | Cookie construction validation. | Yes | Cookie module |
| 6 | `packages/platform-node/test/HttpServer.test.ts` | `"schemaBodyUrlParams"` / `"schemaBodyUrlParams error"` | Decode URL-encoded form bodies and map errors to 400. | Yes | URL-encoded form parser |
| 7 | `packages/platform-node/test/HttpServer.test.ts` | `"schemaBodyFormJson"` variants | Extract JSON from form fields/files/URL params. | Yes | Form parser + schema integration |
| 8 | `packages/platform/test/HttpApp.test.ts` | `"stream"` / `"stream scope"` | Response stream finalization ordering. | Partial | No |
| 9 | `packages/platform-node/test/HttpServer.test.ts` | `"client abort"` / `"causeResponse uses client abort when present"` | Map client disconnect to 499. | Unclear | No |
| 10 | `packages/platform-node/test/HttpServer.test.ts` | `"bad middleware responds with 500"` | Unhandled failures in wrapper turn into 500. | Partial | No |

### Medium priority

| # | File | Test / behavior | Why it matters | Eta gap | Needs new module |
|---|------|-----------------|----------------|---------|------------------|
| 11 | `packages/platform-node/test/HttpServer.test.ts` | `"schema"` — path-param extraction with schema and JSON response encoding | Router + schema validation. | Yes | Router |
| 12 | `packages/platform-node/test/HttpServer.test.ts` | `"mount"` / `"mountApp"` / `"includePrefix"` | Sub-router mounting and path stripping. | Yes | Router |
| 13 | `packages/platform-node/test/HttpServer.test.ts` | `"error/RouteNotFound"` / `"error/schema"` / `"respondable schema"` | Typed errors mapping to HTTP responses. | Partial | Response-mapping DSL |
| 14 | `packages/platform-node/test/HttpServer.test.ts` | `"concat"` / `"concatAll"` | Router composition. | Yes | Router |
| 15 | `packages/platform-node/test/HttpServer.test.ts` | `"setRouterConfig"` | Max param length configuration. | Yes | Router |
| 16 | `packages/platform-node/test/HttpServer.test.ts` | `"multiplex"` | Host-based routing (exact, prefix, regex). | Yes | Router |
| 17 | `packages/platform-node/test/HttpServer.test.ts` | `"file"` / `"fileWeb"` | File responses with content-type, length, etag, last-modified. | Yes | Static file helper |
| 18 | `packages/platform-node/test/HttpServer.test.ts` | `"html"` / `"htmlStream"` | HTML response builders. | Yes | HTML response helper |
| 19 | `packages/platform/test/HttpClient.test.ts` | `describe("retryTransient")` | Status-code retry classification (408, 429, 500, 502–504). | Partial | No |
| 20 | `packages/platform/test/HttpClient.test.ts` | `"google withCookiesRef"` | Cookie jar propagation between requests. | Yes | Cookie jar |
| 21 | `packages/platform/test/HttpClient.test.ts` | `"matchStatus"` | Status-pattern matching (2xx, explicit codes, fallback). | Yes | Client helper |
| 22 | `packages/platform/test/HttpClient.test.ts` | `"followRedirects"` | Redirect following with method/body semantics. | Yes (by design) | Redirect follower |
| 23 | `packages/platform/test/HttpBody.test.ts` | contentType variants | JSON/URL-param body content-type overrides. | Partial | No |
| 24 | `packages/platform/test/Headers.test.ts` | `describe("Redactable")` / `describe("redact")` / `describe("remove")` | Header redaction for observability. | Partial | Header redaction helper |
| 25 | `packages/platform/test/HttpClient.test.ts` | `"fetch removes content-length header"` | Client strips body-length headers when transport sets them. | Partial | No |
| 26 | `packages/platform/test/UrlParams.test.ts` | `makeUrl` / `fromInput` / `toRecord` / `getAll` / `getFirst` / `getLast` / `set` / `append` | Full query-param algebra. | Yes | Query-param module |
| 27 | `packages/platform-node/test/HttpServer.test.ts` | `"tracing"` | Client→server span parenting. | Partial | Tracer integration |

### Lower priority / out of scope

- `packages/platform-node/test/HttpApi.test.ts` and `packages/platform/test/HttpApiBuilder.test.ts` — high-level typed API builder, OpenAPI generation, security middleware, group/endpoint DSL. Porting wholesale requires an `eta_http_api` package. Extract individual behaviors (schema validation, auth, error status mapping) into the items above instead.
- `packages/platform-node/test/HttpServer.test.ts` WebSocket / `Socket.test.ts` / `RpcServer.test.ts` — WebSocket server and RPC-over-WS are not in Eta's current surface (only WS client codec/connection exists).
- `packages/platform-node/test/HttpServer.test.ts` `HttpLayerRouter` tests — depends on Effect's layer/router abstraction.
- `packages/platform-node/test/HttpServer.test.ts` `"uninterruptible routes"` — specific to Effect's interruption semantics; Eta has its own cancellation model.

---

## Recommended first ports

Start with tests that require no new public modules and fill real gaps in Eta's
existing H1/H2 server runtime:

1. **HTTP/1.1 keep-alive semantics** (zio-http `KeepAliveSpec.scala`).
2. **Automatic HEAD handling** (zio-http `MethodAnyHeadSpec.scala` and
   `ServerSpec.generateHeadRoutesSpec`).
3. **Size-limit status codes** (zio-http `NettyMaxHeaderLengthSpec.scala`,
   `NettyMaxInitialLineLengthSpec.scala`).
4. **Server/client streaming interop** (zio-http `ClientStreamingSpec.scala`,
   `RequestStreamingServerSpec.scala`).
5. **Concurrent streaming load** (zio-http
   `RequestStreamingConcurrencySpec.scala`).
6. **Adversarial client connection behavior** (zio-http `ClientSpec.scala`
   connection-failure cases).
7. **Server lifecycle / port binding** (zio-http `ServerStartSpec.scala`).
8. **Stream finalization ordering** (Effect `HttpApp.test.ts` `"stream"` /
   `"stream scope"`).
9. **Client disconnect → 499 mapping** (Effect `HttpServer.test.ts`
   `"client abort"`).
10. **Unhandled middleware/handler failure → 500** (Effect `HttpServer.test.ts`
    `"bad middleware responds with 500"`).

After those, the next valuable layer is **multipart/form-data parsing and
limits** (Effect `Multipart.test.ts`, `HttpServer.test.ts` formData family) and
**cookie construction** (Effect `Cookies.test.ts`, zio-http `CookieSpec.scala`),
because both require new modules that many HTTP applications expect.

---

## Notes on cloning

Both references were cloned shallowly and symlinked:

```sh
mkdir -p ~/projects/github
git clone --depth 1 https://github.com/zio/zio-http.git ~/projects/github/zio-http
ln -sfn ~/projects/github/zio-http /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio-http

git clone --depth 1 https://github.com/Effect-TS/effect.git ~/projects/github/effect
ln -sfn ~/projects/github/effect /home/ribelo/projects/ribelo/ocaml/Eta/.reference/effect
```

Symlinks are intentionally outside the dune build tree so they do not affect
normal builds or `dune runtest`.
