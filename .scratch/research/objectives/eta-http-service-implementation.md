# eta_http_service implementation objective

Status: ready for implementation.

## Objective

Implement Eta's HTTP service layer for building small HTTP microservices, based
on the accepted research conclusion in
`.scratch/research/evidence/eta_http_service_api/README.md`. Read that
promoted summary before coding. Do not rediscover the API from scratch.

The deliverable is two optional Eta packages:

- `eta_http_service` exposing `Eta_http_service`
- `eta_http_service_eio` exposing `Eta_http_service_eio`

This is not a Rails/Django/Spring framework. Eta must not own application state,
database wiring, dependency containers, sessions, templates, controllers,
models, route auto-discovery, or a global app object. Applications own those
things. Eta owns a small set of reusable HTTP modules that compose around the
existing `Eta_http.Server.handler` seam.

The universal seam remains `Eta_http.Server.handler`. Every public service-layer
piece must either be that handler, wrap that handler, or compile to that
handler. Do not introduce a competing handler abstraction or a second runtime
model.

## Package Boundaries

Add `eta_http_service` as a protocol-neutral package depending on `eta`,
`eta_http`, `eta_router`, and `yojson`. It must not depend on Eio.

Add `eta_http_service_eio` as the Eio-bound serving package depending on
`eta_http_service` and `eta_http_eio`.

Do not add service-layer dependencies to the root `eta` package. Follow the
repository rule that opam package name, Dune public library name, and top-level
module line up.

## Required eta_http_service Surface

Implement the service layer proven by the research:

- `Req`: routed request wrapper around the immutable raw
  `Eta_http.Server.Request.t`, matched params, and matched route pattern.
- `Router`: method-aware bridge over `eta_router` that compiles to
  `Eta_http.Server.handler`.
- `Extractors`: typed pulls from `Req.t` for route params, query params,
  headers, request body text, and JSON body decoding.
- `Json`: small response helper for JSON responses with the correct content
  type.
- `Middleware`: ordinary handler-to-handler functions for request id, access
  logging, timeout, admission, CORS, and bearer-auth hook.

Keep the public `.mli` files small and explicit. Prefer obvious helper names
over a clever DSL. The result should feel like Axum/Tower/Ring components in
OCaml, not like a framework.

Router requirements:

- reuse `eta_router`; do not write another path matcher;
- support method-specific routes and explicit method-agnostic routes;
- return 404 for path misses;
- return 405 with `Allow` for path matches with the wrong method;
- expose route params and the matched template through `Req`;
- reject duplicate routes, invalid patterns, empty method sets, and ambiguous
  method-specific/any combinations loudly;
- do not silently default an omitted method list;
- do not bake consumer-specific path aliases such as `/api` into Eta.

Extractor requirements:

- missing required route params, invalid ints, malformed query encoding, JSON
  parse errors, and JSON decode errors fail through
  `Eta_http.Server.Error.Bad_request`;
- query parsing percent-decodes keys and values, treats `+` as a space, and
  preserves duplicate keys;
- body extraction uses the existing server-body reading path and enforces an
  explicit maximum body size;
- extractors return typed Eta failures, not response values and not exceptions.

Middleware requirements:

- middleware remains plain handler composition;
- ordering is onion order: outermost enters first and exits last;
- timeout uses Eta's timeout machinery and typed server errors;
- admission uses Eta's semaphore;
- auth policy remains caller-owned through a supplied verifier;
- logging is injectable so tests do not have to print.

Route-template observability belongs at the router match point, because global
middleware cannot know which template matched. Preserve the matched template in
`Req`. If v1 emits observability attributes, emit the template as `http.route`
and do not use response headers as the production mechanism.

## Required eta_http_service_eio Surface

Implement a small `Serve` module with H1 and H2C entry points. These functions
wrap existing `Eta_http_eio.Server.run_h1` and `run_h2c`; they must not duplicate
protocol server logic.

The serving helpers must make the already-existing graceful shutdown path
discoverable and hard to forget:

- support simple host/port or address configuration suitable for real services;
- default to loopback, not public bind-all;
- install a readiness gate;
- expose `/ready` unless the user handler already owns it;
- on `SIGTERM`, flip readiness to 503 before resolving the stop promise for
  graceful drain;
- pass config and error hooks through to the underlying server.

Do not implement HTTPS, multi-listener orchestration, socket activation, PROXY
protocol, mTLS, automatic OTel, automatic metrics, or TLS policy automation in
this objective. Those are not v1 service-layer requirements.

## Dogfood Scope: inn

The same implementation agent must migrate the real Eta consumer at
`/home/ribelo/projects/ribelo/inn`.

`inn` is in scope because it is the best proof that the API works and is
convenient. It currently uses raw `eta_http` directly and has the exact service
plumbing this package is meant to remove: local JSON helpers, manual query
parsing, repeated method checks, a large route match, manual path params, and
direct `run_h1` usage.

Required `inn` outcome:

- depend on `eta_http_service` and `eta_http_service_eio`;
- build `Inn.Server.handler` with the new router;
- use route params for trace/span identifiers;
- use query extractors for query parsing, limits, and `attr.*` filters;
- use the shipped JSON response helper instead of local content-type plumbing;
- preserve `/api/...` aliases exactly as today;
- preserve existing response bodies, statuses, endpoint inventory, and OpenAPI
  output unless a deliberate bug fix is documented;
- run the server through the new `Serve.h1` path. If `Serve.h1` cannot preserve
  `inn`'s host/port behavior, improve `Serve.h1` rather than leaving `inn` on
  raw `Eta_http_eio.Server.run_h1`.

Use `inn` as a hard API-quality check. If the migration still requires repeated
manual method checks, query decoding, JSON header construction, or a giant path
match, the Eta API is not finished.

## Tests And Verification

Add focused Eta tests for the new packages. Prefer handler-only tests for the
protocol-neutral service behavior and a small Eio integration test for the serve
entry points. Cover routing, 404/405, registration failures, query decoding,
typed extractor failures, JSON body handling, middleware ordering, request id,
timeout, admission, and readiness.

Run the relevant Eta build and test gates before handoff, including `@install`,
the existing HTTP suites, and the new service package suites. Run the `inn`
build and tests after migration. If local package pinning or opam switch work is
needed for `inn` to consume the modified Eta packages, document exactly what was
done. Do not vendor Eta into `inn`.

## Completion Criteria

The objective is complete only when:

- `eta_http_service` and `eta_http_service_eio` are installable packages;
- their public interfaces are small, documented, and match the research
  direction;
- `Eta_http.Server.handler` remains the only service seam;
- router, request wrapper, extractors, JSON helper, middleware, and Eio serve
  helpers are implemented;
- Eta tests prove the new behavior;
- `inn` is migrated to the new API and its tests pass;
- the accepted evidence is summarized in
  `.scratch/research/evidence/eta_http_service_api/README.md`;
- no root `eta` dependency grew;
- no framework-owned application concepts were introduced.
