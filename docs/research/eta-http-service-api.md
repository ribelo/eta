# eta_http_service — API Recommendation

Research outcome of the `eta_http_service` evidence-based-coding lab
(worktree `Eta-http-service-api`, branch `research/eta-http-service-api`).
Date: 2026-06-18. Evidence artifacts under
`.scratch/eta_http_service_api/` and the buildable lab under
`evidence_http_service/`.

## Recommendation (direct)

**Build `eta_http_service` now**, shaped as an Axum/Tower/Ring-style component
vocabulary — not a Rails/Django monolith. v1 ships three protocol-neutral
composable pieces over the shared `Eta_http.Server.handler` type, reusing
`eta_router`, plus one Eio-bound operator piece in a sibling package:

| Package | Piece | What it does |
| --- | --- | --- |
| `eta_http_service` → `Eta_http_service` | **Router bridge** | Method-aware routing over `eta_router`, with **404** (path miss) and **405** (path exists, wrong method). Collapses `inn`'s 60-arm `match` + 21 `require_method` into per-route declarations. |
| `eta_http_service` | **Extractors** | Axum `FromRequest`, Eta-typed: `Param.int "id"`, `json_body decode`, `query`, `header`. Handlers declare dependencies as typed arguments; decode/validation failures stay in the typed-failure channel (server renders `Bad_request`→400). Lowest call-site LOC of every shape tested. |
| `eta_http_service` | **Middleware (Layers)** | `handler -> handler` components (NOT a new type): request id, access log, per-route timeout, admission, CORS, auth hook, **route-template observability** (`http.route` OTel attr). |
| `eta_http_service_eio` → `Eta_http_service_eio` | **`Serve.h1` / `Serve.h2c`** | Thin readiness-gate + SIGTERM→graceful-drain wrapper over `run_h1`/`run_h2c`. `inn` shipped without graceful shutdown because the `?stop` path wasn't discoverable; this fixes that. |

Reject the alternatives: Branch C (monolithic typed-endpoint DSL) is rejected as
a whole (its typed-pull idea is salvaged as Extractors); Branch D (docs only) is
falsified by `inn`'s hand-written plumbing.

## The north star (from the project owner)

> "Build a private OxCaml framework. One monorepo. NOT Django/Rails/Spring.
> Prefer Clojure/Rust: assemble from components that fit together perfectly and
> talk using the same types. Think Axum + Tower, or Clojure Ring."

Every design choice below follows from this. The framework IS being built; this
doc defines the **HTTP layer's first package**.

## Evidence that falsified the alternatives

Full detail in `.scratch/eta_http_service_api/`. Headline numbers:

- **`inn`** (real `eta_http` consumer, ~60 routes): hand-wrote a 60-arm
  path/method `match`, **21 `require_method`** (405) call sites, ~80 LOC of
  query/percent-decode plumbing, JSON/status helpers, and **no graceful
  shutdown** (`run_h1` with no `?stop`, killed via `SIGTERM`→`SIGKILL`). Did not
  use `eta_schema` or `eta_router` despite both existing.
- **P2 call-site LOC** for the same 5-route spec: Extractors **22**, Branch A
  37, Branch C 85, vs `inn`'s 36-line match for a fraction of its routes.
- **Gates**: `test/http` = 343, `test/http_eio` = 145 (both green); lab builds
  clean against the current checkout; no repo regressions.
- **All four shapes** (A, C, Extractors, socket) pass identical 7-route
  handler-only assertions; A+Extractors pass a 5-case end-to-end socket test.

## Design contract (the laws every piece obeys)

1. **One handler type.** Every piece speaks
   `Request.t -> (Response.t, Error.t) Effect.t` (or a routed wrapper that
   compiles to it). No parallel handler types. (Tower/Ring core law.)
2. **Reuse `eta_router`.** The radix trie exists; the bridge adds method
   dispatch + 404/405 + params. No second router.
3. **`middleware = handler -> handler`.** (Dream and Ring both spell it this
   way; confirmed V-DREAM-1.) A `Layer.t` naming wrapper is optional for stack
   clarity; it must not break composition.
4. **Typed failures, not exceptions.** Extractors fail typed (`Bad_request`);
   the server's existing `default_error_response` renders to the wire. No
   branch-and-return-Response in every handler.
5. **No application state, no env channel.** Dependencies are ordinary OCaml
   (closures, args, records). (AGENTS.md + `docs/services.md`.)
6. **Components, not conventions.** No global app, no auto-discovery. Each piece
   is adoptable alone.

## Migration story (raw `Eta_http.Server.handler` → `eta_http_service`)

A raw handler stays a valid handler. Adoption is incremental:

```ocaml
(* before: hand routing + params + 405 inside one giant match *)
let handler request = match request.path, request.method_ with ...

(* after: declare routes; the bridge owns 404/405 + params *)
let service =
  let t = Eta_http_service.Router.create () in
  Eta_http_service.Router.add t "/items/{id}"
    (fun req ->
      let* id = Extractors.Param.int "id" req in
      Effect.pure (Response.json ~status:200 (`Assoc [...])));
  Eta_http_service.Router.add t ~methods:[ "POST" ] "/items"
    (fun req ->
      let* item = Extractors.json_body decode_item req in
      ...);
  Eta_http_service.Router.compile t
```

The compiled value IS an `Eta_http.Server.handler`, so it drops straight into
`Eta_http_eio.Server.run_h1` (or `Eta_http_service_eio.Serve.h1`).

## Minimal first-implementation plan

Two packages, mirroring the existing `eta_http` / `eta_http_eio` split.

### `eta_http_service` (depends `eta`, `eta_http`, `eta_router`, `yojson`)
- `Router` — bridge over `eta_router`: `create`, `add ?methods pattern route`,
  `compile : t -> Server.handler`, 404 (`Server.Handler.route_not_found`) + 405.
- `Req` — routed request: `{ raw; params }` + accessors.
- `Extractors` — `Param.{string,int}`, `Query`, `header`, `body_string`,
  `json_body decode`; `route1/route2/route3` adapters (extend arity as needed).
- `Middleware` — `Layer` = `handler -> handler`; helpers `request_id`,
  `access_log`, `timeout budget`, `admission sem`, `with_route_template`.
- Optional: a Yojson `JSON_ADAPTER` for `eta_schema.Make` so JSON decode works
  out of the box (P1 F1: today every user writes ~42 lines of adapter).

### `eta_http_service_eio` (depends `eta_http_service`, `eta_http_eio`)
- `Serve.h1 ~port ~handler ?config ()`, `Serve.h2c` — readiness gate +
  SIGTERM→graceful-drain over `run_h1`/`run_h2c`. (`Serve.https` is a follow-up.)

### Out of scope for v1 (explicitly deferred)
- Branch C monolithic endpoint DSL / OpenAPI generation (return only if a
  contract-first need appears; then as a piece *on top of* extractors).
- Cookie jar, multipart/form-data, static files, SSE, WebSocket **server**
  upgrade, template engine, sessions, CSRF, ORM — all application/framework
  concerns; separate packages if ever.
- `Serve.https`, multi-listener, socket activation, PROXY protocol, mTLS.
- Auto-OTel/metrics/TLS in `Serve` (the monolith trap). OTel is already
  `eta_otel`; TLS is `eta_http_eio`.

## Open questions that remain after evidence

1. **`Server.Error` taxonomy gap** (the only real error-handling friction, P1
   F2): no `Conflict`(409)/`Unprocessable`(422)/`NotFound`-domain kinds. Two
   clean options for v1: (a) extend `Server.Error` in `eta_http` with a few
   kinds (small, discoverable), or (b) a service-layer `map_error` that maps a
   domain-error row to statuses. Recommend (a) for discoverability; decide in
   implementation.
2. **Route-template observability depth:** v1 stamps `http.route`; full
   span-name templating (`GET /items/{id}`) is a follow-up.
3. **`Layer.t` vs plain functions:** ship plain `handler -> handler` first; add
   a `Layer` naming wrapper only if real stacks show ordering confusion.

## Required test gates before merging

```sh
eval $(opam env)   # or: nix develop -c ...
dune build @install
dune runtest test/http --force          # 343 today
dune runtest test/http_eio --force      # 145 today
dune runtest test/eta_http_service --force   # NEW package suite (handler-only
                                            # tests for router/extractors/middleware,
                                            # reusing the existing test-request helpers)
# one Eio socket integration test in test/eta_http_service_eio
```

The NEW suite should mirror `inn`'s pattern: handler-only tests calling the
compiled `Server.handler` with synthetic `Request.t`s (no sockets), plus one
socket test per `Serve.*` entry point. The P2/P4 lab already proves both shapes.

## Examples to promote into docs

From the lab (`evidence_http_service/`), promote into `docs/`:
- **First 15 minutes**: `p2_candidates/extractors_example.ml` — health + param
  route + JSON POST, the canonical small service.
- **Middleware stack**: `p1_baseline/middleware_service.ml` — request id / auth /
  access log / timeout / admission as `handler -> handler` layers.
- **Graceful shutdown + readiness**: `p4_operator/operator.ml` — the `Serve.h1`
  piece and the direct-`run_h1` recipe side by side.
- **JSON with `eta_schema`**: `p1_baseline/json_service.ml` — incl. the
  `JSON_ADAPTER` recipe (until a shipped Yojson adapter exists).

## Verdict ledger

- **V-P2-1** Router bridge (Branch A): ACCEPT (foundation).
- **V-P2-2** Monolithic endpoint DSL (Branch C whole): REJECT; SALVAGE extractors.
- **V-P2-3** Extractors (Axum-style): ACCEPT (headline).
- **V-P2-4** Docs-only (Branch D): REJECT (falsified by inn).
- **V-DREAM-1..5** No `Middleware.t` new type; method-keyed routes; no `run`
  monolith; immutable req/resp; `scope` deferred.
- **V-P3** Middleware=no new type; server owns error→status seam; `http.route`
  = real value; per-route timeout/admission/limit = middleware components.
- **V-P4-1..3** Small `Serve` readiness/drain piece in `eta_http_service_eio`;
  NOT a monolith; no auto-OTel/TLS in v1.

The shipped code and this journal agree: build `eta_http_service` as the
Axum/Tower/Ring-shaped component layer over `eta_http` + `eta_router`.
