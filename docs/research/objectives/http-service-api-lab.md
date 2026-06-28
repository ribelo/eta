# eta_http_service API Research Lab

Worktree: `../Eta-http-service-api`
Branch: `research/eta-http-service-api`
Role: researcher/orchestrator for an evidence-based-coding agent.

This worktree exists to answer one question:

> What is the smallest, best public API Eta should add so ordinary OCaml
> microservices can be built on `eta_http` without turning Eta into Rails,
> Django, or an application framework?

The expected output is a researched API recommendation backed by local code,
tests, examples, and cited repo evidence. Do not ship a speculative framework.
The main job is discovery: find what the interface should look like, what fits
Eta's design best, and what feels convenient and obvious to an Eta user.

## Ground Rules

- Use evidence-based coding: local source reads, runnable prototypes, focused
  tests, API sketches compiled by Dune, and explicit falsification.
- Do not assume the answer is `eta_http_service`. That name is a candidate,
  not a verdict. The lab may conclude that the best interface belongs in
  `eta_http`, in a smaller package, or only in docs.
- Prefer existing Eta contracts. The current low-level handler type is:
  `Eta_http.Server.Request.t -> (Eta_http.Server.Response.t,
  Eta_http.Server.Error.t) Eta.Effect.t`.
- Preserve Eta's core boundary: applications own state; Eta owns effect
  description, interpretation, lifecycle protocols, and HTTP transport
  invariants.
- Do not add Layer, Context, Tag, service locator, controller classes, ORM,
  template engine, session framework, asset pipeline, or admin framework.
- No compatibility shims. If an API shape is wrong, reject it and document why.
- Keep experiments in `.scratch/eta_http_service_api/` or another clearly
  marked lab area unless a small production change is required to prove a
  point.
- If a public package is recommended, use the naming policy:
  `eta_http_service` opam package, `eta_http_service` public library,
  `Eta_http_service` top-level module.

## What "Best API" Means

Judge every candidate on three axes. Do not collapse them into one vague DX
score.

### Fit For Eta

An interface fits Eta when:

- dependencies are ordinary OCaml values, records, modules, or closures;
- the result compiles down to `Eta_http.Server.handler` without hiding the
  existing server contract;
- typed failures, cancellation, body streaming, response stream release, and
  observability remain explicit enough to reason about;
- optional dependencies stay in optional packages;
- the interface removes repeated protocol glue rather than owning application
  state.

### Convenient

An interface is convenient when common microservice handlers need little
ceremony:

- a health endpoint is one or two lines;
- a JSON endpoint can read, validate, and respond without repeated boilerplate;
- middleware composition has an obvious order and type;
- route params and query params are easy to access and easy to validate;
- tests can run handlers without opening sockets;
- the same handler can still be mounted on H1, h2c, or HTTPS through
  `Eta_http_eio.Server`.

Measure convenience with code, not taste: call-site LOC, required type
annotations, imports, repeated helper code, and number of places a user can
forget cleanup, redaction, body limits, or error mapping.

### Obvious

An interface is obvious when a user who knows Eta can predict it:

- names line up with existing modules: `Handler`, `Route`, `Router`,
  `Middleware`, `Request`, `Response`, `Json`, `Error`;
- no hidden environment or global app object appears;
- small examples read top-to-bottom in ordinary OCaml;
- escape hatches return to `Eta_http.Server.handler`, not to private internals;
- invalid states fail at construction or compile time where practical.

Test obviousness by writing examples before docs. If the example needs a long
paragraph to explain why it works, the interface is probably wrong.

## Local Evidence To Read First

Read these before designing APIs:

- `AGENTS.md`
- `README.md`
- `docs/api-dx.md`
- `docs/services.md`
- `docs/packages.md`
- `lib/http/README.md`
- `docs/http-server-production-readiness-audit.md`
- `docs/porting-http-test-candidates.md`
- `lib/http/server.mli`
- `lib/http/server_request.mli`
- `lib/http/server_response.mli`
- `lib/http/server_body.mli`
- `lib/http/server_config.mli`
- `lib/http_eio/server.mli`
- `lib/http_eio/server_types.mli`
- `lib/router/eta_router.mli`
- `lib/router/router.mli`
- `lib/schema/eta_schema.mli`
- `test/http/test_eta_http_h1_server.ml`
- `test/http/test_eta_http_h2_server.ml`
- `test/http_common/server_common_suites.ml`
- `examples/http_handlers.ml`

Reference code is allowed as prior art, not dependency:

- `.reference/effect-smol` for Effect-style HTTP/server API ideas when present.
- `.reference/oxmono` for OCaml library style.
- `.reference/riot` for larger OCaml application/server conventions.
- `.reference/zio-http` and `.reference/effect` only if present locally.

## Questions To Answer

Answer all of these with evidence. Each answer should cite files, prototypes,
or tests.

1. Should this be a new package `eta_http_service`, additions to `eta_http`, or
   only docs/examples?
2. What is the minimal API surface for microservices: router, middleware,
   codecs, server runner, or all of these?
3. Should the exported handler type be exactly `Eta_http.Server.handler`, or
   should routes receive an enriched request context with params and route
   pattern metadata?
4. What router API is best: mutable build/freeze, functional builder, list of
   route declarations, or a thin adapter over `Eta_router.Router.t`?
5. How should method routing work, including `HEAD`, `OPTIONS`, `404`, and
   `405`?
6. How should route params, query params, and schema validation compose without
   adding an environment channel?
7. What is the smallest useful middleware type? Confirm ordering, typed failure
   propagation, defect handling, cancellation, and response finalization.
8. Which middleware helpers should ship first: request id, access log, tracing,
   CORS, auth hook, per-route timeout, per-route body limit, and concurrency
   admission?
9. How should JSON request/response helpers use `eta_schema` and `yojson`
   without forcing application-wide schema style?
10. Should URL-encoded forms, multipart, cookies, redirects, content
    negotiation, static files, SSE, and WebSocket server upgrade be in the
    first package, later optional modules, or out of scope?
11. What response/error API should map domain errors to HTTP responses without
    hiding `Eta_http.Server.Error.t`?
12. How should route pattern names appear in spans, metrics, and access logs
    while preserving Eta's default redaction behavior?
13. What operator runner belongs in this package, if any: bind config,
    graceful shutdown, health/readiness/draining endpoints, signal handling,
    OTel wiring, and HTTPS config?
14. How do per-route limits and timeouts compose with existing global
    `Eta_http.Server.Config.t`?
15. What examples prove the API: health/readiness, JSON CRUD-ish endpoint,
    outbound HTTP client call, DB-like dependency capture, streaming response,
    and middleware failure?
16. What does a user test look like without sockets? What does one Eio
    integration test look like with sockets?
17. Which existing `docs/porting-http-test-candidates.md` gaps are stale
    because tests have since landed, and which still require new public API?
18. What should explicitly not be built now?

## Candidate API Branches

Test these seriously. Add a fourth branch only if evidence forces it.
The point is not to defend these exact branches; it is to force several
substantially different interface shapes before deciding.

### Branch A: Minimal Service Adapter

New package with:

- route declarations compiled to `Eta_http.Server.handler`;
- method/path routing using `Eta_router`;
- params on request context;
- `not_found` and `method_not_allowed`;
- plain function middleware;
- JSON/schema helpers;
- access-log/tracing helpers;
- no process-level server runner.

This branch wins if most friction is handler composition and body/error helper
boilerplate, not server startup.

### Branch B: Microservice Runtime Kit

Branch A plus an explicit runner:

- bind H1/h2c/HTTPS through `Eta_http_eio.Server`;
- config from ordinary values, not global env;
- graceful shutdown and readiness/draining state;
- request id, access logs, basic metrics/OTel hooks;
- health/ready endpoint helpers.

This branch wins only if evidence shows every realistic service repeats the
same boot/shutdown/observability code and Eta can centralize it without owning
application state.

### Branch C: Typed Endpoint Builder

Higher-level API:

- method/path/schema/body/response/error declared together;
- automatic request decode and response encode;
- route params and query schemas;
- typed error-to-response mapping.

This branch must prove it is not too large or framework-shaped. It loses if
it forces a single schema style, grows an application model, or makes simple
handlers harder to read.

### Branch D: No New API

Docs and examples only:

- show `Eta_router` plus `Eta_http.Server.handler`;
- provide recipes for JSON, middleware, access logs, readiness, and testing;
- no new public package.

This branch wins if prototypes are already simple with existing primitives and
the missing piece is discoverability.

## Required Probes

### P0: Current-State Inventory

Refresh the audit against this checkout.

Deliverables:

- `.scratch/eta_http_service_api/p0_inventory.md`
- List what is already present.
- List stale claims in `docs/porting-http-test-candidates.md`.
- Record exact commands run and results.

Minimum gates:

```sh
nix develop -c dune runtest test/http --force
nix develop -c dune runtest test/http_eio --force
```

### P1: Baseline Without New API

Write 3 small services using only existing public APIs:

1. health/readiness plus graceful shutdown handle;
2. JSON request/response endpoint with schema decode and domain error mapping;
3. middleware stack with request id, auth hook, access log, and per-route
   timeout or concurrency limit.

They may live under `.scratch/eta_http_service_api/p1_baseline/`.

Measure:

- call-site LOC;
- repeated helper code;
- testability without sockets;
- Eio integration complexity;
- where mistakes are easy.

If this is already clean, Branch D is strong evidence.

### P2: Prototype Candidate APIs

Implement enough of Branches A, B, and C to compile the same 3 services from
P1. These can be local modules in scratch; do not need polished production
code.

Each candidate must include:

- public-looking `.mli` sketch;
- usage examples;
- at least one handler-only test;
- at least one Eio socket test or a clear reason it is unnecessary.
- a "first 15 minutes" example showing what a new Eta user writes;
- a short note explaining why this interface is deep rather than pass-through.

Capture:

- `.scratch/eta_http_service_api/p2_candidates/branch_a/`
- `.scratch/eta_http_service_api/p2_candidates/branch_b/`
- `.scratch/eta_http_service_api/p2_candidates/branch_c/`
- `.scratch/eta_http_service_api/p2_candidates/matrix.md`

### P3: Edge Semantics

For the surviving candidates, prove these semantics:

- middleware order;
- handler typed failure vs defect;
- cancellation and response stream release;
- unread request body policy;
- route-not-found and method-not-allowed behavior;
- automatic or explicit `HEAD` and `OPTIONS`;
- route template propagation into observability;
- redaction of query, auth, cookie, and set-cookie data;
- per-route timeout/body-limit/admission behavior.

Capture runnable tests or fixtures. Prose alone is not evidence.

### P4: Operator Surface

Decide whether a runner belongs in `eta_http_service`.

Compare:

- using `Eta_http_eio.Server.run_*` directly;
- a thin `Eta_http_service_eio.run` helper;
- a documented recipe only.

Use a runnable example with graceful shutdown and readiness/draining state.
Do not add ambient global config.

### P5: Final Recommendation

Write `docs/research/eta-http-service-api.md` with:

- recommended package/module/API shape;
- rejected alternatives and why;
- open questions that remain after evidence;
- migration story from raw `Eta_http.Server.handler`;
- minimal first implementation plan;
- exact test gates to require before merging;
- examples that should become docs.

## Decision Criteria

Prefer the branch that:

- hides repeated protocol/lifecycle complexity behind a small interface;
- keeps handler code ordinary OCaml;
- composes with explicit application dependencies;
- preserves typed failure, cancellation, streaming, and resource release;
- makes route-level observability better than ad hoc handlers;
- stays small enough that an Eta user can learn it in one sitting;
- scores best across fit, convenience, and obviousness using the measured
  examples, not personal preference.

Reject a branch if:

- it creates a framework identity for Eta;
- it owns application state;
- it adds a service locator or environment channel;
- it forces all users into schema-first endpoint declarations;
- it is only a thin rename of already-simple existing primitives;
- it makes raw `Eta_http.Server.handler` harder to use or understand.

## Expected Final Shape

The final answer should be direct:

- "Build `eta_http_service` with API X", or
- "Do not build it; add docs/examples Y", or
- "Build only package Z first and defer the rest."

Do not end with a vague menu. Make a recommendation and show the evidence that
falsified the alternatives.
