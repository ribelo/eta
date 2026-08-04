# Eta Crux V1 design

## Authority

This directory is the implementation authority for Eta Crux V1.

- [Public API](public-api.md) defines the complete package and OCaml surface.
- [Wire protocol](wire-protocol.md) defines the semantic frames and encodings.
- [Semantic laws](semantic-laws.md) defines all required behavior.
- [Verification](verification.md) defines the test and performance gates.

The semantic laws take precedence if explanatory text is ambiguous. The
first-principles [design map](../../wayfinder/eta-crux-first-principles/map.md)
records why this design was selected. Its resolved tickets and tracked research
are provenance, not additional requirements.

The old `docs/requirements/eta-crux/` bundle and the old
`docs/wayfinder/eta-crux/` map were removed. They described commands,
subscriptions, fragments, and backend choices that are not part of this design.

## Purpose

Eta Crux is an Eta-native framework for incremental, composable state machines.
It is generic application-computation infrastructure. It is not a UI framework.

An application builds an immutable `'a Eta_crux.t` description. A root
instantiates that description in a private Eta Signal graph. The root advances
one action at a time and produces one complete typed output.

Eta owns effects, scopes, cancellation, resources, supervision, and causes.
Eta Crux owns computation structure, identity, advancement, typed output, and
the shell protocol.

## Architecture

The design has four layers:

1. The computation layer describes values, state machines, dynamic structure,
   keyed children, lifecycle programs, sources, exports, and request exports.
2. The root layer instantiates one description and performs atomic advancement.
3. The driver layer delivers output and shell requests through one-shot tokens.
4. A host adapter reconciles output and performs host-owned work.

The application cannot observe whether the shell uses local typed delivery or
serialized delivery. The serialized binding adds wire validation and session
administration before the shared typed boundary.

## Package graph

```text
eta_crux      -> eta, eta_observability, eta_signal, eta_signal_map, eta_stream
eta_crux_json -> eta_crux, yojson
eta_crux_sexp -> eta_crux
eta_crux_test -> eta_crux, eta, eta_test
```

Each opam package, public Dune library, and top-level OCaml module uses the same
underscore name. V1 has no PPX package and no concrete host-adapter package.

`eta_crux` is one wrapped library. `eta_crux_json` and `eta_crux_sexp` contain
the two exact envelope codecs. `eta_crux_test` contains test controls over the
production driver. Concrete adapters remain in their host projects.

Eta Crux uses the public `Eta_signal_map.Keyed_map` node for `Assoc`. It uses
Eta supervision and `Supervisor.Scope.request_cancel` for owned work. It does
not use private cross-package hooks.

## Public modules

`Eta_crux` exports these modules:

- `Syntax`, `Endpoint`, `Diagnostic`, `State_machine`, `Assoc`, and `Source`
- `Exported_endpoint`, `Request_export`, `Request`, `Requester`, and `Responder`
- `Host_operation`, `Root`, `Post_commit`, `Failure`, and `Driver`
- `Adapter`, `Hosted`, `Wire`, and `Serialized_session`

`Eta_crux.lifecycle` is a top-level constructor. Internal graph, scope,
registry, transaction, and binding modules remain private.

## Deliberate exclusions

V1 has no renderer, widget model, command algebra, subscription algebra,
fragment tree, typed observation plan, middleware chain, graph inspection,
action history, replay, or compatibility protocol.

V1 also has no detached work, retained inactive child, unbounded capacity,
default timeout, streaming request, protocol negotiation, or transport selected
by application code.

## Provenance

The main decision records are:

- [Graph-neutral computations](../../wayfinder/eta-crux-first-principles/issues/03-public-computation-api.md)
- [Deterministic advancement](../../wayfinder/eta-crux-first-principles/issues/06-advancement-transaction.md)
- [Lifetime ownership](../../wayfinder/eta-crux-first-principles/issues/07-dynamic-lifetime-ownership.md)
- [Host adapter](../../wayfinder/eta-crux-first-principles/issues/10-generic-host-adapter.md)
- [Failure boundary](../../wayfinder/eta-crux-first-principles/issues/11-failure-boundary.md)
- [Requests](../../wayfinder/eta-crux-first-principles/issues/13-host-capabilities-and-requests.md)
- [Wire protocol](../../wayfinder/eta-crux-first-principles/issues/17-wire-codec-protocol.md)
- [Transport equivalence](../../wayfinder/eta-crux-first-principles/issues/18-transport-equivalence.md)

The complete index remains in the
[first-principles map](../../wayfinder/eta-crux-first-principles/map.md).
