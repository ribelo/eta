# P9 logger domain results

## Question

Can Eta expose a user-facing Logger API backed by OCaml algebraic effects that
works across Eio fibers and OCaml domains, while preventing normal users from
breaking the logger?

## Probe shape

The probe models the strongest viable public shape:

- Logger_service.info : string -> unit is the only user logging call.
- The raw effect constructor Emit is defined only in logger_service.ml and
  hidden by logger_service.mli.
- Runtime.run installs the hidden native-effect handler.
- If a user-created Eio fiber or OCaml domain loses the handler, info falls
  back to runtime-carried logger state:
  - Eio fiber-local storage for same-domain fibers.
  - Domain-local storage with split_from_parent for raw Domain.spawn.
- Outside the runtime, info fails loudly with Not_configured.

This is deliberately not the fragile pure-handler design from P1. It is a
hardened user API that uses native effects where the handler is present and
uses runtime-carried state to preserve Logger behavior across concurrency
boundaries that do not inherit handlers.

## Commands

    nix develop -c dune build scratch/eta_research/effect_services
    nix develop -c dune exec scratch/eta_research/effect_services/p9_logger_domain/logger_domain_probe.exe

Negative raw-constructor check:

    nix develop -c env LOGGER_EFFECT_NEG=raw_constructor \
      dune build scratch/eta_research/effect_services/p9_logger_domain/raw_constructor_negative.exe

The negative command must fail with:

    Error: Unbound constructor "Logger_effect_probe.Logger_service.Emit"

## Runtime output

    case=fake_handler_cannot_intercept status=PASS result=not-configured fake_handled=false
    case=sibling_outer_not_hijacked status=PASS bodies=[outer-sibling] paths=[handler] allowed=[handler,fiber-local-fallback] domains=[0]
    case=sibling_inner status=PASS bodies=[inner-1,inner-2] paths=[handler,handler] domains=[0,0]
    case=nested_runtime_outer status=PASS bodies=[outer-1,outer-2] paths=[handler,handler] domains=[0,0]
    case=nested_runtime_inner status=PASS bodies=[inner] paths=[handler] domains=[0]
    case=outside_runtime_fails_loudly status=PASS raised=Not_configured
    case=runtime_owned_domain_handler status=PASS bodies=[owned-domain] paths=[handler] domains=[1]
    case=raw_domain_fallback status=PASS bodies=[raw-domain] paths=[domain-local-fallback] domains=[2]
    case=runtime_owned_eio_both_handler status=PASS bodies=[owned-left,owned-right] paths=[handler,handler] domains=[0,0]
    case=raw_eio_fiber_does_not_break_logger status=PASS bodies=[left,right] paths=[fiber-local-fallback,handler] allowed=[handler,fiber-local-fallback] domains=[0,0]
    case=same_domain_handler status=PASS bodies=[root] paths=[handler] domains=[0]
    logger domain probe passed

## Evidence table

| Case | Result | Meaning |
| --- | --- | --- |
| Same-domain runtime use | PASS, handler path | Normal Logger.info works as an algebraic effect under the runtime handler. |
| Raw Eio.Fiber.both inside runtime | PASS, mixed handler/fiber-local fallback | User-created Eio fibers do not lose logs even when one branch loses the handler. |
| Runtime-owned Eio both | PASS, handler path | Eta-owned concurrency can reinstall the handler and keep the effect path. |
| Raw Domain.spawn inside runtime | PASS, domain-local fallback | A user-created domain inherits runtime logger state through DLS and logs instead of breaking. |
| Runtime-owned domain spawn | PASS, handler path on another domain | Eta-owned domain entry can install the handler and preserve effect-backed logging. |
| Outside runtime | PASS, Not_configured | Missing runtime does not silently drop logs; it fails loudly. |
| Nested runtimes | PASS | Inner logger does not corrupt outer logger after return. |
| Sibling during nested runtime | PASS | Eio fiber-local priority prevents a nested logger from hijacking a sibling. |
| Fake handler | PASS | A user-defined effect handler cannot intercept the hidden logger effect. |
| Raw constructor access | PASS as negative compile failure | Users cannot name Emit through the public module interface. |

## Verdict

Yes, Eta can expose a Logger API that users call without passing a logger
argument and that continues to work across normal Eio fibers and OCaml domains.

The implementation must be a hardened runtime-owned design:

1. Hide the native effect constructor.
2. Install the handler in Eta runtime scopes and Eta-owned domain entries.
3. Carry the configured logger in Eio fiber-local storage and Domain-local
   storage so user-created fibers/domains still log when handler inheritance is
   absent.
4. Fail loudly outside a configured runtime.

This provides real user value for Logger specifically: call-site ergonomics for
a cross-cutting service, without letting ordinary users intercept the hidden
effect or accidentally drop logs by spawning Eio fibers or domains inside the
runtime.

## Limits

This proof does not justify a general service system. The robust behavior comes
from Logger-specific fallback semantics and a thread-safe sink. It is not a
pure algebraic-effect service substrate.

Normal users can still get Not_configured by calling Logger.info before
entering the runtime. Unsafe code such as Obj, direct mutation of private
runtime internals, or bypassing Eta entirely is outside the guarantee. The
negative fixture proves the ordinary public API does not expose the raw effect
constructor.

## What would overturn this result

- A fixture showing Logger.info can silently drop a record inside Runtime.run
  under ordinary Eio or Domain use.
- A public-interface compile probe that can name or handle the hidden Emit
  constructor without unsafe features.
- A domain-safe implementation requirement that forbids carrying the logger sink
  through DLS or requires portable-only callbacks for all user domain use.
