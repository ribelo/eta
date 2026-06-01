# Hardening

Eta keeps sanitizer and fuzzing runs opt-in so the normal test loop stays fast.

## C Stubs: ASan/UBSan

Run the ASan-compatible C-stub suites under AddressSanitizer and
UndefinedBehaviorSanitizer with:

~~~sh
nix develop -c bash scripts/hardening/asan-ubsan-runtest.sh
~~~

Pass a Dune target to narrow the run:

~~~sh
nix develop -c bash scripts/hardening/asan-ubsan-runtest.sh test/sql
nix develop -c bash scripts/hardening/asan-ubsan-runtest.sh test/http
~~~

For test binaries that need Alcotest case selection, use the generic wrapper:

~~~sh
nix develop -c bash scripts/hardening/asan-ubsan.sh \
  exec test/connectors/test_connectors.exe -- test duckdb 0-3,5
nix develop -c bash scripts/hardening/asan-ubsan.sh \
  exec test/connectors/test_connectors.exe -- test turso 0-1,3-4
nix develop -c dune build --profile asan \
  test/connectors/libeta_ladybug_test_extension.lbug_extension
nix develop -c env \
  ETA_LADYBUG_TEST_EXTENSION=_build/default/test/connectors/libeta_ladybug_test_extension.lbug_extension \
  bash scripts/hardening/asan-ubsan.sh \
  exec test/connectors/test_connectors.exe -- test ladybug
~~~

The script selects Dune profile `asan` and sets conservative defaults:

- `CC=clang`
- `ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:strict_string_checks=1`
- `UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1`

Leak detection starts disabled because the OCaml runtime, `dlopen`-loaded
database engines, and OpenSSL can produce noisy process-lifetime reports. Enable
LSan only for a narrower harness after confirming the runtime/dependency noise
floor.

The connector RSS-growth regression is intentionally excluded from the DuckDB
ASan subset because ASan quarantine changes process RSS. Run that regression in
the normal test profile.

Turso's native library normally uses `RTLD_DEEPBIND` isolation. ASan rejects
`dlopen` with `RTLD_DEEPBIND`, so sanitizer builds omit that flag in the
Turso stub. The Turso typed mutation test is currently excluded from the ASan
subset because it observes different `sqlite3_changes` behavior without that
binding isolation. Keep the normal-profile test as the source of truth for that
case until there is a sanitizer-compatible Turso library/load strategy.

MemorySanitizer is intentionally not wired here. MSan is useful only when the
OCaml runtime and all relevant C dependencies are also built with MSan
instrumentation; a partial MSan build gives misleading coverage and noisy
reports.

## HTTP Fuzzing

Run a short Crowbar smoke pass with:

~~~sh
nix develop -c dune build @fuzz-smoke
~~~

Run a longer local pass with:

~~~sh
nix develop -c dune build @fuzz
~~~

Set repeat counts explicitly when needed:

~~~sh
ETA_FUZZ_SMOKE_REPEAT=1000 nix develop -c dune build @fuzz-smoke
ETA_FUZZ_REPEAT=100000 nix develop -c dune build @fuzz
~~~

Crowbar failures should be minimized and promoted into deterministic Alcotest
regressions before or alongside the fix. The fuzz harnesses target Eta-owned
protocol boundaries and invariants, not third-party parser internals for their
own sake.
