# Diffable map evidence manifest

Date: 2026-08-01

This manifest records immutable revisions for the source reviews in this
research bundle.

## Eta

- Repository revision: `dbc470105790bc50d7ed34c72f965431c4657d8a`
- [Keyed assoc and stable child identity](../../../docs/wayfinder/eta-crux-first-principles/issues/04-keyed-assoc-contract.md)

## Jane Street map sources

- Reviewed Base source in `avsm/oxmono` at
  `4e3b745fb95d66fa0e13601d7fa7aeaed7962043`.
- The last change to `opam/base/src/map.ml` at that revision is
  `2796201dcbd4cb28abe908537f514b24d11e036f`.
- [Reviewed Base map implementation](https://github.com/avsm/oxmono/blob/4e3b745fb95d66fa0e13601d7fa7aeaed7962043/opam/base/src/map.ml)
- [Reviewed Base map interface](https://github.com/avsm/oxmono/blob/4e3b745fb95d66fa0e13601d7fa7aeaed7962043/opam/base/src/map_intf.ml)
- [Reviewed Base map tests](https://github.com/avsm/oxmono/blob/4e3b745fb95d66fa0e13601d7fa7aeaed7962043/opam/base/test/test_map.ml)
- [Reviewed Base package metadata](https://github.com/avsm/oxmono/blob/4e3b745fb95d66fa0e13601d7fa7aeaed7962043/opam/base/base.opam)
- Installed Core documentation version:
  `core.v0.18~preview.130.91+190`.
- Official Base cross-check revision:
  `28d466710aa1858a70fd3c1fcbeae07a07ac8106`.
- [Official Base map cross-check](https://github.com/janestreet/base/blob/28d466710aa1858a70fd3c1fcbeae07a07ac8106/src/map.ml)

## Incremental map sources

- `Incr_map` revision:
  `21c6bc602c75d57242b4c3e945da597f82c6280f`.
- [Incr_map implementation](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map.ml)
- [Incr_map interface](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map_intf.ml)
- Incremental tutorial file revision:
  `6253411aa37e1ae758908bd285930659119eff2a`.
- [Incremental map tutorial](https://github.com/janestreet/incremental/blob/6253411aa37e1ae758908bd285930659119eff2a/doc/part3-map.mdx)

## Standalone package checks

- Containers revision:
  `4948d74e45994304e3dda764f6616c7f6988c493`.
- [Containers map interface](https://github.com/c-cube/ocaml-containers/blob/4948d74e45994304e3dda764f6616c7f6988c493/src/core/CCMap.mli)
- Batteries revision:
  `f947f6627462e8935522e987befd42eec6ba19ba`.
- [Batteries map interface](https://github.com/ocaml-batteries-team/batteries-included/blob/f947f6627462e8935522e987befd42eec6ba19ba/src/batMap.mli)
- `ptmap` package version: `2.0.5`.
- `gmap` package version: `0.3.0`.

## Algorithm references

- Nievergelt and Reingold, *Binary search trees of bounded balance*, 1973.
  DOI: `10.1145/800152.804906`.
- Hirai and Yamamoto, *Balancing weight-balanced trees*, 2011.
  DOI: `10.1017/S0956796811000104`.
- Blelloch, Ferizovic, and Sun, *Just Join for Parallel Ordered Sets*, 2016.
  DOI: `10.1145/2935764.2935768`.
