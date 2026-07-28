# `Effect.all` omission-site census

Final lexical census after the admission split and test migration. Comments and
string literals are excluded; `Effect.all`, `Eta.Effect.all`,
`Eta_js.Effect.all`, and the test alias `E.all` are included.

**Result:** 106 omission sites; 106 safe-to-widen; 0 load-bearing.
No omission was rebound. The 55 consumer/example/benchmark sites match the
sealed one-line predictions in `../journal.md`; verification callers are
recorded individually because their assertions, not hidden admission, own their
behavior.

| Site | Classification | Evidence |
| --- | --- | --- |
| `bench/fixtures/typecheck/deep_bind/tp_m01.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m02.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m03.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m04.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m05.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m06.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m07.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m08.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m09.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m10.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m11.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m12.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m13.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m14.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m15.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m16.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m17.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m18.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m19.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m20.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m21.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m22.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m23.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m24.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m25.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m26.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m27.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m28.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m29.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m30.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m31.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m32.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m33.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m34.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m35.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m36.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m37.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m38.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m39.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m40.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m41.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m42.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m43.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m44.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m45.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m46.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m47.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m48.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m49.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/fixtures/typecheck/deep_bind/tp_m50.ml:9` | safe-to-widen | Fixed literal of three independent immediate effects; effective admission was already three. |
| `bench/runtime_concurrency/runtime_concurrency.ml:18` | safe-to-widen | Benchmark is named for the public `all` engine and must measure its unbounded admission. |
| `bench/runtime_concurrency/runtime_concurrency.ml:19` | safe-to-widen | Benchmark is named for the public `all` engine and must measure its unbounded admission. |
| `examples/all_health_checks.ml:11` | safe-to-widen | Fixed three-check example; effective admission was already three. |
| `examples/all_health_checks.ml:14` | safe-to-widen | Fixed three-check example; effective admission was already three. |
| `lib/eta/pool.ml:102` | safe-to-widen | Fixed four-metric batch; effective admission was already four. |
| `test/api_dx/api_dx_examples.ml:522` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/cache/test_eta_cache.ml:119` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/cache/test_eta_cache.ml:135` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/cache/test_eta_cache.ml:282` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/cache_jsoo/test_eta_cache_jsoo.ml:120` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/cache_jsoo/test_eta_cache_jsoo.ml:136` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/cache_jsoo/test_eta_cache_jsoo.ml:308` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/core_common_suites.ml:1426` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/core_common_suites.ml:1427` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_common_suites.ml:887` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_common_suites.ml:898` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_common_suites.ml:2358` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_common_suites.ml:2388` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_common_suites.ml:2424` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_common_suites.ml:2740` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_common_suites.ml:2746` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_common_suites.ml:2764` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_common_suites.ml:2885` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_common_suites.ml:2953` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_common_suites.ml:3449` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_common_suites.ml:3478` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_common_suites.ml:3650` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/effect_interruptible_shared.ml:81` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/observability_common_suites.ml:1419` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/promise_shared.ml:82` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/stress_common_suites.ml:60` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/stress_common_suites.ml:96` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/stress_common_suites.ml:390` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/stress_common_suites.ml:409` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/core_common/upstream_invariants_common_suites.ml:104` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/effect_introspection/snapshot_effect_describe.ml:16` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/eta/test_eta_effect_core.ml:330` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/http/test_eta_http_h2_connection.ml:250` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/http_js/run_http_js_tests.ml:419` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/http_js/run_http_js_tests.ml:436` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/js_jsoo/test_eta_js_jsoo.ml:133` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/laws/law_properties.ml:735` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/laws/law_properties.ml:822` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/laws/law_properties.ml:883` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/laws/law_properties.ml:948` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/laws/law_properties.ml:1336` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/laws/law_properties.ml:1702` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/laws/law_properties.ml:2036` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/runtime_common/runtime_common_suites.ml:458` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/runtime_common/runtime_common_suites.ml:481` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/runtime_common/runtime_common_suites.ml:493` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/stream_common/stream_common_suites.ml:1124` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/test/test_eta_test.ml:586` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/test_common/test_common_suites.ml:122` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/type_errors/cases_runtime/cross_domain_channel.ml:64` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
| `test/type_errors/cases_runtime/cross_domain_channel.ml:95` | safe-to-widen | Verification-only caller with no caller-owned cap-eight protocol; asserted behavior is preserved under full admission. |
