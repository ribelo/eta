# Package and module boundaries

Type: grilling
Status: resolved
Blocked by: 04, 08, 10, 12, 14

## Question

Which final responsibilities belong in `eta_crux`, `eta_signal`, test support,
and concrete host packages?

Decide the package and dependency graph for:

- the public computation API and runtime driver.
- private or public `eta_signal` engine hooks.
- keyed `assoc` support.
- deterministic test harnesses.
- generic adapter support.
- the generic source producer and the optional Eta stream bridge.
- Sliml and later host adapters.
- optional PPX syntax, if retained.

Apply the repository's install-only-what-you-use rule. The root `eta` package
must not depend on Eta Crux. Do not split a package only to hide an internal
module. Keep host-specific, FFI, test, and PPX dependencies out of ordinary Eta
Crux applications.

## Answer

### Package graph

Eta Crux uses these package dependencies:

```text
eta_crux      -> eta
eta_crux      -> eta_signal -> eta, eta_observability, eta_stream
eta_crux      -> eta_signal_map -> eta_signal
eta_crux      -> eta_stream
eta_crux_json -> eta_crux, yojson
eta_crux_sexp -> eta_crux
eta_crux_test -> eta_crux, eta, eta_test
```

Each arrow points from a package to its dependency. The Crux-specific direct
dependencies are:

- `eta_crux` depends on `eta`, `eta_signal`, `eta_signal_map`, and `eta_stream`.
- `eta_crux_json` depends on `eta_crux` and `yojson`.
- `eta_crux_sexp` depends on `eta_crux` only.
- `eta_crux_test` depends on `eta_crux`, `eta`, and `eta_test`.
- `eta_signal_map` depends on `eta_signal`.

The existing `eta_signal` package already depends on `eta_stream`. The direct
`eta_stream` dependency in `eta_crux` supports its small stream-to-source
adapter. A separate package for this adapter does not reduce the installed
dependency set.

The root `eta` package has no Eta Crux dependency. `eta_signal`, `eta_signal_map`,
and `eta_test` also have no Eta Crux dependency.

Each opam package, public Dune library, and top-level OCaml module uses the same
underscore name. V1 has no dotted public library and no PPX package.

### Core library

`eta_crux` is one wrapped library. Its top-level module is `Eta_crux`.

The public submodules are:

- `Syntax`
- `Endpoint`
- `State_machine`
- `Assoc`
- `Source`
- `Root`
- `Driver`
- `Adapter`
- `Hosted`
- `Exported_endpoint`
- `Request_export`
- `Request`
- `Requester`
- `Responder`
- `Host_operation`
- `Post_commit`
- `Failure`
- `Diagnostic`
- `Wire`
- `Serialized_session`

`Eta_crux.lifecycle` remains a top-level constructor. The public API has no
separate lifecycle module.

This library owns the computation descriptions, root interpreter, driver,
generic adapter resource, hosted loop, typed source protocol, identity binding,
and serialized binding. It also owns the semantic frame type, session state,
and codec signature for serialized delivery.

`Wire` contains the semantic frame type and the envelope-codec signature.
`Serialized_session` contains the serialized binding and its administration
capability.

The identity binding does not allocate wire frames, sequences, tokens, encoded
payloads, or serialized registries. An identity integration does not install an
envelope-codec package.

The library hides the graph interpreter, export registry, session registry,
structural transaction state, and other runtime implementation modules. These
modules do not form a public Expert API.

### Eta Signal boundary

Eta Crux depends only on public `eta_signal` and `eta_signal_map` interfaces. It
does not use a private Dune library from either package.

`eta_signal_map` owns the transactional keyed-map node from
[Keyed assoc and stable child identity](04-keyed-assoc-contract.md). It exposes
a public `Keyed_map (M : Map.S)` functor next to the existing `Keyed` API. The
node uses the supplied `M` operations and preserves the laws from that ticket.

`Eta_crux.Assoc (M)` uses this public node. Eta Crux does not implement a second
keyed graph node or expose the Eta Signal structural protocol.

If implementation work proves that Eta Crux needs another engine hook, the hook
must enter the public `eta_signal` or `eta_signal_map` API. It must have named
laws and executable coverage. Eta Crux does not use a private cross-package hook
or publish a generic graph Expert API.

### Envelope codecs

Eta Crux owns the closed driver-envelope protocol. Applications and integrations
own codecs for root output, exported payloads, requests, and responses.

`eta_crux_json` provides the exact JSON envelope codec. It uses `yojson` for the
JSON lexical grammar. The package implements the strict frame validation,
canonical base64url rules, and protocol-error mapping itself.

`eta_crux_sexp` provides the exact S-expression envelope codec. It implements
the restricted flat-list grammar directly and adds no S-expression dependency.

Neither package depends on `eta_schema`. An application can use
`eta_schema_yojson` to implement its application-value codecs independently.

A serialized transport installs exactly one envelope-codec package. The
transport does not negotiate the encoding.

### Test support

`eta_crux_test` contains the public production-driver handle from
[Deterministic testing contract](12-testing-contract.md). It also contains the
controlled source and the recording generic adapter.

The expectation helpers use the same Alcotest-backed failure channel as
`Eta_test.Expect`. Alcotest enters through `eta_test`. The `eta_crux_test`
package does not declare a second direct Alcotest dependency.

The general `Eta_test.Controlled` effect helper belongs to the existing
`eta_test` package. It has no Eta Crux dependency.

Private race barriers, internal conformance scenarios, and generated law tests
remain in the repository test tree. They are not part of `eta_crux_test`.
QCheck remains a test-only dependency.

### Concrete host adapters

The generic adapter contract and hosted driver loop stay in `eta_crux`. They use
no toolkit, FFI, or host-specific dependency.

A concrete host adapter belongs to its host project and package. The Sliml
adapter belongs in the Sliml repository. It depends on `eta_crux` and Sliml.
Its same-process FFI integration uses the identity binding and no envelope-codec
package.

A future serialized adapter also depends on one selected envelope-codec package.
If this repository later ships a concrete host adapter, its package name is
`eta_crux_<host>`. V1 ships no concrete host adapter from this repository.
