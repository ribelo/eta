# Eta Package Map

Eta ships as multiple opam packages in one repository. Pick only the ones you
need; OCaml's link-time dead-code elimination drops modules you never reach, and
opam keeps optional dependency cost honest at the package boundary.

## Discoverability

```sh
ocamlfind list | grep '^eta'
ocamlfind query eta_http -recursive
ocamlfind query eta_http -format "%d/%a"
```

Every package below has a one-line `description` recorded in its META, so
`ocamlfind list` is self-explanatory.

## Packages and their cost

The right column is the *additional* opam dependencies a package brings beyond
what its parents already required. Package names link directly to library
modules: `(libraries eta_http)` in your `dune` file imports `Eta_http.*`.

| ocamlfind name        | toplevel module       | extra deps it pulls in                                                              |
| --------------------- | --------------------- | ----------------------------------------------------------------------------------- |
| `eta`                  | `Eta`                  | —                                                                                   |
| `eta_blocking`         | `Eta_blocking`         | —                                                                                   |
| `eta_eio`              | `Eta_eio`              | eio, cstruct                                                                        |
| `eta_par`              | `Eta_par`              | native domains/threads only                                                         |
| `eta_stream`           | `Eta_stream`           | cstruct                                                                             |
| `eta_redacted`         | `Eta_redacted`         | —                                                                                   |
| `eta_schema`           | `Eta_schema`           | —                                                                                   |
| `eta_sql`              | `Eta_sql`              | sqlite3 (C library, via pkg-config)                                                 |
| `eta_turso`            | `Eta_turso`            | `eta_sql` chain; loads `libturso_sqlite3` at runtime                                |
| `eta_http`             | `Eta_http`             | h2, hpack, faraday, angstrom, decompress, bigstringaf, domain-name, ipaddr, openssl |
| `eta_otel`             | `Eta_otel`             | yojson, eta_http chain                                                              |
| `eta_ai`               | `Eta_ai`               | yojson, eta_http chain                                                              |
| `eta_ai_openai`        | `Eta_ai_openai`        | eta_ai_openai_codec, eta_stream                                                     |
| `eta_ai_anthropic`     | `Eta_ai_anthropic`     | (subset of eta_ai)                                                                  |
| `eta_ai_openrouter`    | `Eta_ai_openrouter`    | eta_ai_openai_codec                                                                 |
| `eta_ai_openai_compat` | `Eta_ai_openai_compat` | eta_ai_openai_codec                                                                 |
| `eta_ai_openai_codec`  | `Eta_ai_openai_codec`  | eta_ai                                                                              |
| `eta_test`             | `Eta_test`             | alcotest, eio_main                                                                  |
| `eta_schema_test`      | `Eta_schema_test`      | alcotest, eta_schema                                                                |

## How OCaml's "tree-shaking" actually works

OCaml has dead-code elimination, but it's coarser than what JavaScript bundlers
do. Two levels matter:

1. **Within a library.** The native linker drops `.cmx` modules that aren't
   reachable from `main`. If `eta_http` contains forty modules and your binary
   only touches five, only those five (plus their transitive callees) are in
   the final executable.

2. **Across libraries.** The granularity is the *ocamlfind package*. The moment
   you add `(libraries eta_http)` to your `dune` file, every package listed in
   `eta_http`'s `requires` line above must be installed on the system. Unused
   ones still won't bloat the binary (level 1 still applies), but they have to
   be present.

The practical rule:

> Heavy dependencies belong in their own ocamlfind package. Don't depend on
> `eta_http` if you only need `eta_stream`.

Eta is structured so this rule is easy to follow. A small CLI uses
`(libraries eta)` and pays for the core runtime only. Add `eta_http` only when
you need the network. Add `eta_sql` only when you need SQLite. And so on.

## SQLite-Compatible Connectors

`eta_sql` and `eta_turso` intentionally keep separate C stubs even where they
call the same `sqlite3_*` API names.

The invariant is the foreign loading contract, not only the C ABI shape:

- `eta_sql` is the system-SQLite package. It compiles against `<sqlite3.h>`,
  links via `pkg-config sqlite3`, and exposes native SQLite operations such as
  backup, restore, extension loading, expanded SQL, and low-level statement
  inspection.
- `eta_turso` is a Turso connector. It loads `libturso_sqlite3` at runtime,
  reports `Library_unavailable` when the engine is absent, and uses
  `RTLD_DEEPBIND` isolation when supported so Turso's SQLite-compatible symbols
  do not collide with the process SQLite.

Shared behavior belongs above that foreign seam: SQL values and rows live in
`Eta_sql`, backend-agnostic query construction lives in `eta_sql_dsl`,
bounded-worker blocking lives in `eta_blocking`, and connector cancellation
policy lives in `eta_sql_driver`. Do not collapse the C stubs into one generic
extension unless the design preserves both foreign contracts explicitly.

## Recipes

### Effect core only
```dune
(executable (name app) (libraries eta))
```
Cost: no runtime backend or native worker dependency.

### Native blocking calls
```dune
(executable (name app) (libraries eta eta_blocking eta_eio))
```
Adds: Eio when using the Eio-backed worker runner.

### Effect core + streams
```dune
(executable (name app) (libraries eta eta_stream))
```
Adds: cstruct.

### HTTP client with retries and tracing
```dune
(executable (name app) (libraries eta eta_http eta_otel))
```
Adds: h2, hpack, faraday, angstrom, decompress, bigstringaf, domain-name,
ipaddr, openssl, yojson.

### LLM chat using OpenAI
```dune
(executable (name app) (libraries eta eta_ai eta_ai_openai))
```
Adds: everything in `eta_http` plus yojson.

### Tests with the virtual clock and cause-aware assertions
```dune
(test (name run) (libraries eta eta_test alcotest))
```

## Notes for AI agents reading this repo

- Every public library lives under `lib/`. Each `lib/X/dune` declares an
  underscore public name such as `(public_name eta_http)`. There is no hidden
  internal namespace; if you can see it via `ocamlfind list`, you can use it
  directly.
- The toplevel module name is the Dune `(name ...)`. Use `Eta_http` in OCaml
  source and `eta_http` in `(libraries ...)`.
- `eta_http` is one library with `(include_subdirs unqualified)`. Its public
  surface is curated in `lib/http/eta_http.{ml,mli}` (`Eta_http.Core`,
  `Eta_http.H1`, `Eta_http.Tls`, etc.). Internal modules under `lib/http/*/`
  are flat siblings, not separate libraries.
- Drivers under `drivers/` are *not* part of the `eta` opam package and are
  invisible to ocamlfind. They depend on Eta, never the other way around.
