# Eta Package Map

Eta ships as one opam package (`eta`) that installs many independent
ocamlfind sub-packages. Pick only the ones you need; OCaml's link-time dead-code
elimination drops modules you never reach, and ocamlfind keeps the transitive
dependency cost honest at the package boundary.

## Discoverability

```sh
ocamlfind list | grep '^eta'
ocamlfind query eta.http -recursive
ocamlfind query eta.http -format "%d/%a"
```

Every package below has a one-line `description` recorded in its META, so
`ocamlfind list` is self-explanatory.

## Packages and their cost

The right column is the *additional* opam dependencies a package brings beyond
what its parents already required. Package names link directly to library
modules — `(libraries eta.http)` in your `dune` file imports `Eta_http.*`.

| ocamlfind name        | toplevel module       | extra deps it pulls in                                                              |
| --------------------- | --------------------- | ----------------------------------------------------------------------------------- |
| `eta`                 | `Eta`                 | eio, eio.unix, threads, portable                                                    |
| `eta.par`             | `Eta_par`             | unix                                                                                |
| `eta.stream`          | `Eta_stream`          | cstruct                                                                             |
| `eta.redacted`        | `Eta_redacted`        | —                                                                                   |
| `eta.schema`          | `Eta_schema`          | —                                                                                   |
| `eta.sql`             | `Eta_sql`             | sqlite3 (C library, via pkg-config)                                                 |
| `eta.http`            | `Eta_http`            | h2, hpack, faraday, angstrom, decompress, bigstringaf, domain-name, ipaddr, openssl |
| `eta.otel`            | `Eta_otel`            | yojson, eta.http chain                                                              |
| `eta.ai`              | `Eta_ai`              | yojson, eta.http chain                                                              |
| `eta.ai.openai`       | `Eta_ai_openai`       | (subset of eta.ai)                                                                  |
| `eta.ai.anthropic`    | `Eta_ai_anthropic`    | (subset of eta.ai)                                                                  |
| `eta.ai.openrouter`   | `Eta_ai_openrouter`   | (subset of eta.ai)                                                                  |
| `eta.ai.openai_compat`| `Eta_ai_openai_compat`| (subset of eta.ai)                                                                  |
| `eta.ai.openai_codec` | `Eta_ai_openai_codec` | (subset of eta.ai, internal-but-public)                                             |
| `eta.test`            | `Eta_test`            | alcotest, eio_main                                                                  |
| `eta.schema_test`     | `Eta_schema_test`     | alcotest, eta.schema, eta.test                                                      |

## How OCaml's "tree-shaking" actually works

OCaml has dead-code elimination, but it's coarser than what JavaScript bundlers
do. Two levels matter:

1. **Within a library.** The native linker drops `.cmx` modules that aren't
   reachable from `main`. If `eta.http` contains forty modules and your binary
   only touches five, only those five (plus their transitive callees) are in
   the final executable.

2. **Across libraries.** The granularity is the *ocamlfind package*. The moment
   you add `(libraries eta.http)` to your `dune` file, every package listed in
   `eta.http`'s `requires` line above must be installed on the system. Unused
   ones still won't bloat the binary (level 1 still applies), but they have to
   be present.

The practical rule:

> Heavy dependencies belong in their own ocamlfind package. Don't depend on
> `eta.http` if you only need `eta.stream`.

Eta is structured so this rule is easy to follow. A small CLI uses
`(libraries eta)` and pays for `eio` plus `threads`. Add `eta.http` only when
you need the network. Add `eta.sql` only when you need SQLite. And so on.

## Recipes

### Effect core only
```dune
(executable (name app) (libraries eta))
```
Cost: eio, eio.unix, threads, portable.

### Effect core + structured concurrency
```dune
(executable (name app) (libraries eta eta.par eta.stream))
```
Adds: cstruct.

### HTTP client with retries and tracing
```dune
(executable (name app) (libraries eta eta.http eta.otel))
```
Adds: h2, hpack, faraday, angstrom, decompress, bigstringaf, domain-name,
ipaddr, openssl, yojson.

### LLM chat using OpenAI
```dune
(executable (name app) (libraries eta eta.ai eta.ai.openai))
```
Adds: everything in `eta.http` plus yojson.

### Tests with the virtual clock and cause-aware assertions
```dune
(test (name run) (libraries eta eta.test alcotest))
```

## Notes for AI agents reading this repo

- Every public library lives under `lib/`. Each `lib/X/dune` declares its
  `(public_name eta.X)`. There is no hidden internal namespace; if you can see
  it via `ocamlfind list`, you can use it directly.
- The toplevel module name is the dune `(name ...)`, *not* the public name.
  Use `Eta_http`, not `eta.http`, in OCaml source.
- `eta.http` is one library with `(include_subdirs unqualified)`. Its public
  surface is curated in `lib/http/eta_http.{ml,mli}` (`Eta_http.Core`,
  `Eta_http.H1`, `Eta_http.Tls`, etc.). Internal modules under `lib/http/*/`
  are flat siblings, not separate libraries.
- Drivers under `drivers/` are *not* part of the `eta` opam package and are
  invisible to ocamlfind. They depend on Eta, never the other way around.
