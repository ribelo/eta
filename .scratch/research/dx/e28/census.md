# DX-E28 Engine Census

This census was completed before choosing C1/C2/C3. It covers executable OCaml
call sites under exactly `lib/`, `test/`, `examples/`, `bench/`,
`http-testsuite/`, and `drivers/`. It excludes API definitions, comments,
documentation prose, expected-error strings, and snippet strings that are not
compiled as the call shown. `all_settled` is not counted: the assignment asks
for every `Effect.all` and `Effect.map_par` call site and gives four categories
specific to those two operations.

The scan included the spellings `Effect`, `Eta.Effect`, `Eta_js.Effect`, and the
local `E` aliases. A broad token scan was reviewed manually to remove unrelated
`all` functions. No applicable call was found in `http-testsuite/` or
`drivers/`.

## Classification rule

The four pre-registered classes are exhaustive when read by task shape:

- **(a) small literal list (at most five):** `all` receives a literal list, or a
  directly visible fixed list of at most five before a local `List.map`.
- **(b) collection mapping:** `map_par` maps a dynamic/generated collection, an
  empty/singleton collection, or a literal collection outside the special 2–3
  item smell in (d).
- **(c) large/dynamic list into `all`:** `all` receives more than five items or
  a variable/generated list whose size is not enforced by `all` itself.
- **(d) 2–3 literal into `map_par`:** a mapper is applied to a literal list of
  two or three values. This records the overlap pressure rather than silently
  flattening it into (b).

## Counts

| Tree | (a) small literal `all` | (b) collection `map_par` | (c) large/dynamic `all` | (d) 2–3 literal `map_par` | Total |
|---|---:|---:|---:|---:|---:|
| `lib/` | 1 | 0 | 1 | 0 | 2 |
| `test/` | 32 | 21 | 16 | 12 | 81 |
| `examples/` | 2 | 1 | 0 | 1 | 4 |
| `bench/` | 50 | 9 | 2 | 50 | 111 |
| `http-testsuite/` | 0 | 0 | 0 | 0 | 0 |
| `drivers/` | 0 | 0 | 0 | 0 | 0 |
| **Total** | **85** | **31** | **19** | **63** | **198** |
| **Share** | **42.9%** | **15.7%** | **9.6%** | **31.8%** | **100%** |

By operation, the census contains 104 `all` calls (85 a, 19 c) and 94
`map_par` calls (31 b, 63 d).

## Complete inventory

Homogeneous generated fixtures are grouped, but every counted call is covered
by one row.

| Class | Count | Call sites |
|---|---:|---|
| (a) | 50 | `bench/fixtures/typecheck/deep_bind/tp_m01.ml` through `tp_m50.ml`, line 9 in each: one three-effect literal `Effect.all`. |
| (d) | 50 | The same 50 files, line 11 in each: `Effect.map_par ~max_concurrent:2 ... [ acc; acc + 1; acc + 2 ]`. |
| (c) | 2 | `bench/runtime_concurrency/runtime_concurrency.ml:18,19`; both helpers pass `List.init n` to `Effect.all` and are exercised at 2, 8, and 64. |
| (b) | 7 | `bench/runtime_concurrency/runtime_concurrency.ml:60,62,64,67,70,73,76`; generated collections of 8, 64, or 512 passed to `map_par`. |
| (b) | 2 | `bench/runtime_real/runtime_real.ml:41,49`; generated collections of 64 and 512 passed to `map_par`. |
| (a) | 1 | `lib/eta/pool.ml:102`; four literal metric updates. |
| (c) | 1 | `lib/js_stream/eta_js_stream.ml:76`; arbitrary stream chunk `xs` is mapped and passed to `Eta_js.Effect.all`. |
| (a) | 2 | `examples/all_health_checks.ml:11,14`; each maps a directly visible three-item literal before `Effect.all`. |
| (d) | 1 | `examples/batch_concurrency.ml:27`; three literal user IDs. |
| (b) | 1 | `examples/mutable_ref_state.ml:26`; maps the four-item `batches` collection, outside category (d)'s exact 2–3 shape. |
| (a) | 2 | `test/http_js/run_http_js_tests.ml:436`; `test/eta/test_eta_effect_core.ml:330`. |
| (c) | 1 | `test/http_js/run_http_js_tests.ml:419`; a `List.map ... cases` collection is passed to `E.all`. |
| (b) | 2 | `test/eta/test_eta_blocking.ml:144,272`; generated 30- and 40-item collections. |
| (b) | 1 | `test/api_dx/api_dx_examples.ml:505`; dynamic `ids` passed to `map_par`. |
| (c) | 1 | `test/api_dx/api_dx_examples.ml:522`; reusable helper passes arbitrary `checks` to `Effect.all`. |
| (a) | 1 | `test/stream_common/stream_common_suites.ml:1124`; two-effect literal. |
| (c) | 1 | `test/http/test_eta_http_h2_connection.ml:198`; `List.init 10` requests passed to `all`. |
| (b) | 1 | `test/http/test_eta_http_h1_client.ml:1784`; `List.init parallelism` passed to `map_par`. |
| (a) | 3 | `test/runtime_common/runtime_common_suites.ml:472,495,507`; three, zero, and two effect literals. |
| (b) | 3 | `test/runtime_common/runtime_common_suites.ml:497,549,563`; empty, four-item, and singleton mapper inputs. |
| (a) | 1 | `test/effect_introspection/snapshot_effect_describe.ml:16`; two-effect literal. |
| (b) | 1 | `test/effect_introspection/snapshot_effect_describe.ml:18`; singleton mapper input. |
| (a) | 1 | `test/test_common/test_common_suites.ml:122`; three-effect literal. |
| (a) | 1 | `test/js_jsoo/test_eta_js_jsoo.ml:133`; two-effect literal. |
| (a) | 3 | `test/cache_jsoo/test_eta_cache_jsoo.ml:121,137,309`; two-effect literals. |
| (a) | 1 | `test/test/test_eta_test.ml:586`; three-effect literal. |
| (b) | 1 | `test/test/test_eta_test.ml:1054`; 10,000 generated inputs with an explicit cap of 64. |
| (b) | 2 | `test/laws/law_properties.ml:505,577`; generated `indexed`/`values` mapper collections. |
| (d) | 1 | `test/laws/law_properties.ml:538`; three literal mapper inputs. |
| (a) | 1 | `test/laws/law_properties.ml:631`; three-effect literal. |
| (c) | 4 | `test/laws/law_properties.ml:604,975,1341,1675`; generated `children`, `senders`, `waiters`, and an 11-effect close-check list passed to `all`. |
| (a) | 2 | `test/cache/test_eta_cache.ml:136,283`; two-effect literals. |
| (c) | 1 | `test/cache/test_eta_cache.ml:120`; eight generated cache waiters passed to `all`. |
| (a) | 1 | `test/core_common/stress_common_suites.ml:409`; two-effect literal. |
| (c) | 3 | `test/core_common/stress_common_suites.ml:60,96,390`; generated lists of 20, 30, and randomized 2–6 effects. |
| (b) | 2 | `test/core_common/stress_common_suites.ml:114,457`; generated 100 inputs and a five-item mapper input. |
| (a) | 1 | `test/core_common/observability_common_suites.ml:1419`; two-effect literal. |
| (d) | 1 | `test/core_common/observability_common_suites.ml:1421`; two literal mapper inputs. |
| (a) | 10 | `test/core_common/effect_common_suites.ml:2543,2573,2609,2742,2748,2753,2874,3304,3333,3505`; zero-to-three effect literals. |
| (c) | 2 | `test/core_common/effect_common_suites.ml:1072,1083`; generated lists of 128 and 6 effects. |
| (b) | 7 | `test/core_common/effect_common_suites.ml:8,247,2810,2816,2826,2981,3006`; singleton, five-item, or generated nine-item mapper inputs. |
| (d) | 9 | `test/core_common/effect_common_suites.ml:2777,2785,2802,2851,2959,3028,3362,3400,3536`; two- or three-item mapper inputs. |
| (a) | 1 | `test/core_common/upstream_invariants_common_suites.ml:104`; three-effect literal. |
| (b) | 1 | `test/core_common/effect_resource_timeout_common_suites.ml:427`; arbitrary `acquisitions` mapped by the documented bounded recipe. |
| (a) | 1 | `test/core_common/promise_shared.ml:83`; three-effect literal. |
| (d) | 1 | `test/core_common/core_common_suites.ml:1421`; three literal publisher inputs. |
| (c) | 2 | `test/core_common/core_common_suites.ml:1426,1427`; two generated six-receive lists. |
| (c) | 1 | `test/core_common/effect_interruptible_shared.ml:84`; 17 mapped values passed to `all`. |
| (a) | 2 | `test/type_errors/cases_runtime/cross_domain_channel.ml:64,95`; two-effect literals. |

The inventory counts sum independently to the aggregate table: (a) 85, (b)
31, (c) 19, and (d) 63.

## Pathological cases, quoted verbatim

### Real, non-test dynamic `all`

`lib/js_stream/eta_js_stream.ml:76` is a category-(c) production call:

```ocaml
Eta_js.Effect.map (fun ys -> Chunk ys)
  (Eta_js.Effect.all (List.map f xs))
```

`xs` is the current stream chunk. Neither this call nor `Effect.all` imposes a
cardinality bound. This is exactly the pre-registered C3 trigger: a dynamic list
into `all` in real code. Calling typical host chunks "reasonable" would be a
silent environmental assumption, not an Eta contract.

### Deliberate unbounded benchmark

`bench/runtime_concurrency/runtime_concurrency.ml:18-19` makes the engine split
observable and includes the 64-way case:

```ocaml
let all n = Effect.all (List.init n (fun _ -> Effect.pure 1))
let all_heavy n = Effect.all (List.init n (fun _ -> work 100))
```

### Large test fan-out

`test/core_common/effect_common_suites.ml:1069-1073` intentionally launches 128
children:

```ocaml
let count = 128 in
let values =
  List.init count (fun _ -> Effect.fresh ())
  |> Effect.all
```

### Literal `map_par` overlap

All 50 typecheck fixtures contain the same category-(d) shape; for example
`bench/fixtures/typecheck/deep_bind/tp_m01.ml:11`:

```ocaml
Effect.map_par ~max_concurrent:2
  (fun n -> Effect.sync (fun () -> services#audit_log n))
  [ acc; acc + 1; acc + 2 ]
```

This high count is generated benchmark boilerplate, not 50 independent product
design choices, but it must remain visible in the raw census.

## Census fact relevant to the later decision

The census contains a real non-test category-(c) site. Per the pre-registered
outcomes, that fact must be carried into the decision stage; this artifact does
not resolve the semantics choice itself.
