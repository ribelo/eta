# Endpoint R — tracing after static-name deletion

The Phase-0 dependency map predicted that `Custom.names` was introspection-only.
Endpoint R confirms the representation can delete it without touching runtime
span naming:

- `lib/eta/effect_core.ml:66-74` — `Custom` now carries only `eval` and
  `leaf_name`; there is no propagated names list.
- `lib/eta/effect_core.ml:109` — evaluation dispatches directly through
  `Custom.eval`.
- `lib/eta/effect_observability.ml:70-82` — `named` captures its `name` argument
  in the evaluator and passes that same value to
  `Runtime_instrument.with_span ~name`.
- Full `dune runtest` and the shipped gate pass the named-span, span-kind, and
  `fn` location witnesses registered in
  `test/core_common/observability_common_suites.ml:1440-1444`.

Therefore R removes the internal static-name mechanism, while the runtime trace
name path remains direct and executable.
