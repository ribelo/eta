## Breaking: observability moved to `eta_observability`

- Added the optional `eta_observability` opam package and public
  `Eta_observability` module.
- Moved the tracing, structured logging, metrics, propagation, and scoped
  observability combinators from `Eta.Effect` to the flat
  `Eta_observability` surface.
- Moved `Eta.Logger`, `Eta.Meter`, `Eta.Tracer`, `Eta.Log_level`, and
  `Eta.Trace_context` to submodules of `Eta_observability`.
- Root `eta` retains capability payload/object contracts and interpreter
  diagnostics, but no longer installs the application-facing SDK.
- `[%eta.sync]` and `[%eta.result]` now expand through
  `Eta_observability.fn` and `Eta_observability.named`; rewritten targets must
  add `eta_observability` to their Dune libraries.
- There are no compatibility modules or forwarding aliases. Update imports,
  call sites, and direct package dependencies together.
- `Eta.Effect.t` now exposes covariance in its typed-error parameter as
  `type ('a, +'err) t`, allowing separately compiled polymorphic SDK constants
  to remain reusable at narrower consumer error types.
