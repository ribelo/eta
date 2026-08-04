---
kind: requirement
tags: [eta_signal, eta_signal_map, kernel, transaction, scope]
refines: ["[[docs/requirements/eta-signal/README]]"]
depends_on: []
traces_to: ["[[docs/prds/0002-eta-signal-frp]]"]
---
# Keyed extension

## Intent

Eta Signal supplies one sealed stable-family protocol to collection packages.
The protocol preserves graph isolation, transaction atomicity, and scoped
lifetime.

The protocol is not an expert API. It exposes no engine mutation authority.

## Requirements

- The `eta_signal` package shall keep keyed collection operations outside its public core API. ^sigext-fhjg
- The Eta Signal graph factory shall expose one opaque graph-branded package endpoint. ^sigext-xv47
- The Eta Signal package endpoint shall accept only sealed stable-family plans and return signals from its graph. ^sigext-0hwu
- Where `eta_signal_map` is installed, the package shall use the public stable-family protocol for keyed diffing and stable child scopes. ^sigext-x5gu
- The `Eta_signal_map.Make` functor shall accept an existing package endpoint and shall not create a graph. ^sigext-m0xu
- The `eta_signal_map` package shall require the same `eta_signal` release version. ^sigext-0g5r
- The `eta_signal` package shall install `eta_signal_kernel` as a package-private Dune library without a public library name. ^sigext-vha2
- The public `eta_signal` library shall expose the existing `Eta_signal` interface through the package-private kernel. ^sigext-acrq
- The public Eta Signal CMI shall not expose a package-private kernel path or type. ^sigext-toyy
- The Eta Signal graph factory shall create a graph type that does not unify with a type from another application. ^sigext-wkb7
- Where a keyed node is included, the private kernel shall create that node in the current valid dynamic scope. ^sigext-6hhm
- Where a keyed node is included, the private kernel shall attach and remove its input and child dependency edges transactionally. ^sigext-oqvb
- When keyed planning creates a provisional scope, the private kernel shall register that scope for rollback before it runs the child builder. ^sigext-o06w
- When structural plans require preflight, the private kernel shall preflight each owner before its descendants. ^sigext-pqzu
- The private kernel shall complete all operations that can fail before a structural transaction commits. ^sigext-zlk8
- When a structural transaction commits, the private kernel shall detach and invalidate all removals before it attaches an addition. ^sigext-9bch
- When structural preflight succeeds, the private kernel shall complete the pure commit without failure. ^sigext-ye7i
- When a dynamic scope becomes invalid, the private kernel shall reject signals captured from that scope. ^sigext-92o4
- When a child output changes, the private kernel shall notify each dependent keyed node without a scan of all retained children. ^sigext-tla9
- The public `Eta_signal` interface shall not expose a graph value, scope handle, raw node constructor, transaction handle, or general mutation capability. ^sigext-f931
