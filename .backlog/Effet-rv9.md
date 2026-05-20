---
id: Effet-rv9
title: Sampling at the runtime layer (V-O9)
status: closed
priority: 3
issue_type: task
created_at: 2026-05-19T14:24:49.908Z
created_by: backlog
updated_at: 2026-05-19T15:12:51.268Z
closed_at: 2026-05-19T15:12:51.268Z
close_reason: Added Runtime.create ?sampler with default Sampler.always_on, new
  Sampler module (always_on/off, ratio, parent_based), runtime sampling
  propagation including unsampled parents across par children, tests for
  always_off/ratio/parent_based/cross-fiber suppression, and nix develop -c dune
  runtest --force passes.
---

# Sampling at the runtime layer (V-O9)

## description

Today every Effect.named / Effect.fn produces an emitted span unconditionally. Production traffic volumes make 100% sampling prohibitive: backends throttle, network bandwidth saturates, ingest costs scale linearly. V-O9 explicitly defers this. The decision belongs at the runtime layer (above tracer trait) so all backends — Tracer.in_memory, Effet_otel, future adapters — benefit from one sampler implementation.

## design

Runtime.create gains optional ?sampler argument: a record/object with one method sample : trace_id:string -> name:string -> attrs:(string * string) list -> parent:bool -> bool. The interpreter Named case calls sampler.sample at begin_span time; if false, skips begin_span/end_span entirely (the body still runs, just no span emission). Decision is sticky for the span's lifetime; child spans of an unsampled parent are also unsampled (inherit via the active-span fiber-local key). Ship three samplers in a new Sampler module: Sampler.always_on (default), Sampler.always_off, Sampler.ratio : float -> sampler (TraceIdRatioBased equivalent using trace_id hash mod 2^64), Sampler.parent_based : ?root:sampler -> unit -> sampler (honor parent's decision when present, fall back to root). Cross-fiber: sampling decision propagates with active-span context via the same Eio.Fiber key A4 set up.

## acceptance criteria

Runtime.create accepts ?sampler with a documented default (always_on). A test with Sampler.always_off and an in-memory tracer verifies zero spans are dumped despite Effect.named usage. A test with Sampler.ratio 0.5 and N=1000 spans asserts roughly 50% sampling rate (within statistical tolerance). A test with Sampler.parent_based: a sampled parent span produces sampled children; an unsampled parent produces no child spans. A test verifies cross-fiber inheritance: par children of an unsampled parent emit zero spans. Existing tests using default sampler continue to pass.
