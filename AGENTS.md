# Repository Guidelines

## Project Structure & Module Organization

Effet is a small OCaml 5 library built with Dune. Public code lives in `packages/effet/`;
each exported module has a paired implementation and interface, for example
`effect.ml` and `effect.mli`. The core modules are `Effect`, `Runtime`,
`Cause`, `Exit`, `Duration`, `Schedule`, `Resource`, `Capabilities`, and
`Tracer`.

Tests live in `packages/effet/test/test_effet.ml` and are registered by
`packages/effet/test/dune`. Research
experiments live under `scratch/`; keep them out of the published library unless
they are deliberately promoted into `packages/effet/`. Generated artifacts belong in
`_build/` and local switches in `_opam/`.

## Build, Test, and Development Commands

- `nix develop -c dune build`: build the library using the pinned Nix shell.
- `nix develop -c dune runtest --force`: run the full test suite.
- `opam install . --deps-only --with-test`: install dependencies without Nix.
- `dune build` / `dune runtest --force`: local equivalents when the OCaml
  environment is already configured.

The package requires OCaml `>= 5.1`, Dune, Eio, Eio_main, and Alcotest.

## Coding Style & Naming Conventions

Follow the existing OCaml style: two-space indentation, concise helper names,
and pipelines where they improve readability. Keep public APIs in `.mli` files
and avoid widening exported types accidentally. Use lowercase snake_case for
values, PascalCase for modules, and polymorphic variants such as `` `Timeout``
for typed failures.

There is no repository formatter configuration at the moment. Match nearby code
and run Dune before submitting changes.

## Testing Guidelines

Tests use Alcotest plus Eio runtime helpers. Add focused `let test_* ()`
functions in `packages/effet/test/test_effet.ml`, then register them in the suite in that file.
Prefer deterministic helpers such as the existing test clock for timeouts,
delays, and fiber scheduling. Cover both `Exit.Ok` and `Exit.Error` paths when
changing runtime interpretation or typed failures.

Run `nix develop -c dune runtest --force` before handing off changes.

## Commit & Pull Request Guidelines

The short history uses conventional-style commits such as `feat: par / all /
for_each_par concurrent combinators`. Keep commit subjects imperative,
specific, and scoped to the change.

Pull requests should describe the behavior change, mention affected modules,
link any relevant issue, and include the exact test command run. For API
changes, call out updates to both `.ml` and `.mli` files.

## Agent-Specific Instructions

Do not treat Effet as an application framework. The README is explicit:
applications own state; Effet owns effect description and interpretation.
Preserve that boundary when adding features.
