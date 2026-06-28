# Eta Drivers

`drivers/` is reserved for optional integration packages that bind Eta-owned
protocols to concrete external engines or services. This directory follows the
Eta-4atr repository layout policy.

Drivers live in `drivers/eta_NAME/`. Each shipped driver has a matching opam
package at the repository root named `eta_NAME.opam`, and that package depends
on `eta`.
The opam package boundary is the dependency boundary: optional engine-specific
dependencies stay out of the core `eta` package, so consumers only install the
drivers they choose.

Use this naming convention for driver libraries:

- directory: `drivers/eta_NAME/`
- opam package: `eta_NAME.opam`
- dune library name: `(name eta_NAME)`
- public library name: `(public_name eta_NAME)`
- OCaml module: `Eta_NAME`

Use engine-specific names when the external dependency is concrete, for example
`drivers/eta_duckdb/` or `drivers/eta_postgres/`. Use a capability or protocol
name only when the driver is genuinely engine-generic.

Driver packages should make ownership clear:

- applications own state, credentials, connection strings, and lifecycle policy;
- Eta owns effect description, typed failures, resource cleanup, and runtime
  observability;
- drivers translate between those boundaries without adding application
  framework behavior.

Do not add compatibility shims for old driver paths. Rename or delete stale
paths and update callers in the same change.

See the repository-level `AGENTS.md` for the general ownership rules that also
apply to drivers.
