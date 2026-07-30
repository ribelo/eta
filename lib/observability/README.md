# eta_observability

Application-facing tracing, structured logging, metrics, and W3C propagation
for Eta.

## Package boundary

`eta_observability` is an optional Batteries package. It depends on root `eta`
and adds no external runtime, wire-format, or exporter dependency. Add it when
application or library code constructs observability effects or uses Eta's
built-in logger, meter, tracer, log-level, or trace-context helpers.

Root `eta` retains only the interpreter contract:

- `Capabilities` payload and object types accepted by runtimes;
- `Runtime_contract` and `Spi.Expert` substrate hooks;
- private span-parenting, capability override, and defect-diagnostic state;
- private noop capabilities needed when no implementation is installed.

The dependency direction is one-way:

```text
eta_observability -> eta
eta -/-> eta_observability
```

An application can therefore install and use `eta` without this SDK. It may
still supply hand-written `Capabilities.logger`, `Capabilities.meter`, and
`Capabilities.tracer` objects directly to a runtime.

## Fiber-local seam

The interpreter owns every fiber-local key that it reads or writes, including
the active span, sampling and ambient propagation context, defect annotations,
capability overrides, daemon log scope/filter/interceptors, and metric
interceptors used by `Spi.Expert` emissions. These keys remain private in root
`eta`.

`eta_observability` accesses that state only through narrow `Spi.Expert`
operations. No runtime-local key is exported to the SDK. This preserves daemon
diagnostics and package-owned SPI emissions without introducing a root-to-SDK
dependency or duplicating state between packages.

## Install and use

```sh
opam install eta_observability
```

```dune
(executable
 (name app)
 (libraries eta eta_observability eta_eio))
```

The DSL is flat so migrated call sites keep their current shape:

```ocaml
open Eta

let work =
  Eta_observability.named "load.user"
    (Eta_observability.log_info "loading" |> Effect.map (fun () -> 42))
```

Capability implementations and propagation helpers are submodules:

```ocaml
let tracer = Eta_observability.Tracer.in_memory ()

let runtime =
  Eta_eio.Runtime.create ~sw ~clock
    ~tracer:(Eta_observability.Tracer.as_capability tracer) ()
```

Exporters remain separate integrations. `eta_otel` depends on this package and
implements the capability records against OTLP; `eta_observability` itself does
not send telemetry.

## Breaking migration

There are no forwarding modules or old-path aliases. Replace:

- `Eta.Effect.named` with `Eta_observability.named` (likewise for every moved
  tracing, logging, and metrics combinator);
- `Eta.Logger`, `Eta.Meter`, `Eta.Tracer`, `Eta.Log_level`, and
  `Eta.Trace_context` with the corresponding `Eta_observability` submodule;
- generated `[%eta.sync]`/`[%eta.result]` dependencies by adding
  `eta_observability`, because the PPX emits `Eta_observability.fn` and
  `Eta_observability.named`.
