---
kind: requirement
tags: [eta_signal_map, package, architecture, overview]
refines: []
depends_on: ["[[docs/requirements/eta-signal/README]]"]
traces_to: ["[[docs/prds/0002-eta-signal-frp]]"]
---
# eta_signal_map

## Intent

`eta_signal_map` provides an immutable diffable map and one keyed Eta Signal
operator. Applications install this package only when they use keyed reactive
collections.

The package keeps persistent ancestry across edits. This ancestry lets the map
and keyed operator make work proportional to a small change frontier.

## Requirements

- The Eta release shall publish optional opam package `eta_signal_map` with public library and module `Eta_signal_map`. ^smpkg-m1km
- The root `eta` package shall not contain the diffable map or keyed signal operator. ^smpkg-t25w
- The root `eta` package shall not depend on `eta_signal_map`. ^smpkg-v3vp
- The `eta_signal` package shall not depend on `eta_signal_map`. ^smpkg-ms1p
- The `eta_signal_map` package shall depend on the exact same release version of `eta_signal`. ^smpkg-kt5y
- The `eta_signal_map` runtime shall not depend on Base, Core, Incremental, or `Incr_map`. ^smpkg-e8ac
- The `eta_signal_map` package shall expose one public map module and one public keyed signal operator in V1. ^smpkg-w9da
- The `eta_signal_map` package shall pass the native OxCaml gate. ^smpkg-x2n6
- The generated `eta_signal_map.opam` file shall declare test-only Alcotest and QCheck dependencies. ^smpkg-1y2y

## Requirement Notes

- [[docs/requirements/eta-signal-map/keyed-map]] — map semantics, keyed child
  behavior, transaction behavior, diagnostics, and complexity.
