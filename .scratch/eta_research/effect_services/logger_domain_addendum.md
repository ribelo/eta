# ADR addendum - user-facing algebraic-effect Logger

## Status

Accepted as a narrow Logger design candidate. This addendum does not reopen the
P1 rejection of native effects as a general service substrate.

## Decision

Eta can provide a user-facing Logger API backed by OCaml algebraic effects if
the public API is hardened:

- users call only Logger.info, Logger.warn, etc.;
- the raw effect constructor is private to Eta;
- Eta runtime installs the handler;
- Eta carries the logger through Eio fiber-local storage and Domain-local
  storage as a fallback for boundaries that do not inherit handlers;
- missing runtime raises a loud error instead of dropping logs.

This design has value for Logger because logging is cross-cutting and appears
deep in call graphs. Avoiding logger-argument plumbing is a real ergonomic win.

## Evidence

Runnable evidence lives in p9_logger_domain/.

The probe proves:

- same-domain Logger.info uses the hidden effect handler;
- raw Eio.Fiber.both inside the runtime still records logs;
- Eta-owned Eio concurrency can keep the handler path;
- raw Domain.spawn inside the runtime still records logs through DLS;
- Eta-owned domain spawn can install the handler in the new domain;
- outside-runtime use raises Not_configured;
- nested logger runtimes restore the outer logger;
- a nested logger does not hijack a sibling Eio fiber;
- a fake user handler cannot intercept Logger;
- the raw effect constructor is unnameable through the public interface.

## Consequences

This is not a generic DI mechanism. It is a Logger-specific API with fallback
state deliberately added because native handlers do not propagate across every
fiber/domain boundary.

The earlier P1 result still stands for arbitrary services: a root-installed
handler alone is not enough. The new result says Logger can be made robust
because Eta can define the whole public API, hide the effect constructor, choose
clear missing-runtime behavior, and use a synchronized logger sink.

## User-breakage claim

Within normal OCaml use of the public API, users cannot break Logger by:

- creating Eio fibers inside the runtime;
- creating OCaml domains inside the runtime;
- nesting logger runtimes;
- defining another handler with a similarly shaped effect;
- naming the raw Logger effect constructor.

Users can still fail loudly by calling Logger outside the runtime. Unsafe
features and direct edits to Eta internals are outside the guarantee.

## Implementation bar for production

A production task would need a real Logger surface, tests mirroring
p9_logger_domain, and a decision on whether fallback paths are acceptable in the
public contract. It should not add a generic Effect.Service system.
