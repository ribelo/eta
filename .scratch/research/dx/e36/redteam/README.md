# DX-E36 red-team pass

The adversarial fixtures were promoted into the normal substrate suites rather
than kept as stale scratch executables:

- native/shared definitions:
  `test/core_common/supervisor_common_suites.ml`;
- js_of_ocaml counterparts: `test/js_jsoo/test_eta_jsoo.ml`.

Re-run:

```sh
nix develop -c dune runtest test/core_eio --force
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force
```

Both commands passed. The first command executes the named shared Supervisor
cases; the second prints each jsoo counterpart as `ok`.

See [old-trap.md](old-trap.md) and
[supervised-non-leak.md](supervised-non-leak.md).
