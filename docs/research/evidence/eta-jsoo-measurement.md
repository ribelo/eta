# Eta jsoo measurement

Date: 2026-06-10

Current js_of_ocaml backend built with `--effects=cps`:

| Bundle | Size | Node runtime |
| --- | ---: | ---: |
| `_build/default/test/js_jsoo/test_eta_jsoo.bc.js` | 4.2 MiB | 0.05 s |
| `_build/default/test/js_jsoo/test_eta_js_jsoo.bc.js` | 4.4 MiB | 0.06 s |
| `_build/default/test/js_stream/run_js_stream_tests.bc.js` | 4.3 MiB | 0.04 s |

Commands:

```sh
nix develop .#mainline -c dune runtest test/js_jsoo test/js_stream --force --display=short
ls -lh _build/default/test/js_jsoo/test_eta_jsoo.bc.js \
  _build/default/test/js_jsoo/test_eta_js_jsoo.bc.js \
  _build/default/test/js_stream/run_js_stream_tests.bc.js
```

The deleted hand-written JavaScript runtime baseline was checked from clean
`HEAD` into `/tmp/eta-js-baseline` and attempted with:

```sh
ETA_JS_TESTS=true dune build @js-tests-build --display=short
```

That baseline did not build in the current `.#mainline` shell because Dune
reported `Library "melange" not found`. I did not reintroduce that dependency
for this migration measurement.
