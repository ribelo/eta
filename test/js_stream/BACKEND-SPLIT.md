# Backend Split

`test/js_stream` is `Eta_js_stream` js_of_ocaml integration coverage. It
compiles the stream facade to JavaScript and runs it under Node through
`Eta_js_test.main`.

The native `Eta_stream` behavior that can be shared across backend surfaces
lives in `test/stream_common`, with the Eio runner. The JS suite remains separate
because it validates the `Eta_js` facade modules, js_of_ocaml compilation, and
Node runtime behavior rather than the native runtime contract directly.
