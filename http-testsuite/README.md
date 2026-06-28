# eta_http Testsuite

Real-server interop, adversarial CVE replay, and quick benchmarks for `eta_http`.

## Quick start

```bash
nix develop -c bash http-testsuite/run.sh
```

Runs all three suites (interop, CVE regress, quick bench). Use `--no-interop`, `--no-cve`, or `--no-bench` to skip layers.

## Running individual suites

```bash
dune build @interop      # interop + differential vs curl
dune build @cve-regress  # adversarial / CVE replay
dune build @h2spec       # HTTP/2 conformance via h2spec, h2c + h2/TLS
dune build @http-bench   # quick latency / allocation / RSS benchmarks
```

Additional opt-in probes:

```bash
dune build @server-load   # smoke server-load harness
dune build @red-probes    # targeted adversarial probes
dune build @eta-lifecycle # Eta server lifecycle probe
dune build @perf-compare  # client performance comparison harness
```

## Output

Each run writes to `http-testsuite/results/<utc-timestamp>-<short-git-sha>/`:

- `manifest.json` — tool versions, host info, git sha
- `interop.json` — flat array of all interop scenario results
- `cve.json` — adversarial scenario results
- `h2spec.json` / `h2spec.md` — HTTP/2 conformance command results and raw artifact paths
- `bench.json` — benchmark iterations
- `summary.md` — human-readable rollup
- `<scenario>_<server>_<protocol>_<transport>/` — per-scenario raw eta + curl outputs when divergent or failed

`results/` is gitignored.

## Adding a scenario

1. Add a scenario record to `http-testsuite/lib/interop.ml` in `default_scenarios`.
2. Re-run `dune build @interop`.
3. Inspect `results/<run-id>/summary.md`.

## Re-running a single scenario

The easiest way is to edit `Interop.default_scenarios` to contain only the scenario you want, then run `dune build @interop`. There is no per-scenario CLI filter in v1.

## Architecture

- `lib/` — OCaml library: server lifecycle, scenario definitions, differential curl testing, report generation
- `test/interop/` — `dune build @interop` entry point
- `test/cve_regress/` — `dune build @cve-regress` entry point
- `test/h2spec/` — `dune build @h2spec` entry point
- `test/bench/` — `dune build @http-bench` entry point
- `test/server_load/` — `dune build @server-load` entry point
- `test/red_probes/` — `dune build @red-probes` entry point
- `test/eta_lifecycle/` — `dune build @eta-lifecycle` entry point
- `test/perf_compare/` — `dune build @perf-compare` entry point
- `expected_divergences.md` — documented fields subtracted before pass/fail

## Servers

Both nginx and Caddy are started fresh per scenario batch on ephemeral loopback ports. Configs are templated per-run; no fixed ports or paths are hard-coded. TLS uses per-run local CA certificates generated with openssl.

## Server-load probes & environment knobs

`test/server_load/` hosts the load/latency harness and standalone server probes
used for performance work (driven by `oha`):

- `run.exe` — the broad server-load suite (Eta vs Node/Go/nginx/Caddy).
- `h1_probe.exe PORT TEMP_DIR` — standalone Eta HTTP/1.1 (plaintext) server.
- `h1_tls_probe.exe PORT TEMP_DIR` — standalone Eta HTTPS (HTTP/1.1 over TLS)
  server; generates a local RSA-2048 cert via `Certs.prepare`.
- `h2_probe.exe`, `mtop.exe` (memtrace CTF top) — H2 probe and alloc profiler.

Environment variables honored by the testsuite Eta server (`lib/eta_server.ml`)
and probes:

| Variable | Default | Effect |
|----------|---------|--------|
| `ETA_SERVER_DOMAINS` | unset → single domain | For the **TLS** server, number of Eio accept/handshake domains (`start_https ~domain_policy:(Additional n)`). Spreads CPU-bound TLS handshakes across `n` cores. Unset/`0` → `Single_domain` (one core). Keep modest: io_uring memlock (`ulimit -l`, ~8 MB here) caps usable domains (~16); `Recommended` (all cores) can fail with `io_uring_queue_init ENOMEM`. |
| `MEMTRACE` | unset | Path for a memtrace CTF dump (probes call `Memtrace.trace_if_requested`). |
| `EIO_BACKEND` | `posix` in harness | Eio backend selection. |

The autoresearch latency harness (`.auto/measure.sh`) also reads `ETA_TLS_DOMAINS`
(→ `ETA_SERVER_DOMAINS`), `ETA_TLS_HS_REQUESTS`, `ETA_TLS_KA_REQUESTS`, and
`ETA_TLS_REPS` to size its runs.

## Differential testing

Every interop scenario runs through both `eta_http` and `curl`. Results are normalized (status, body SHA-256, sorted headers/trailers with stochastic fields stripped) and compared. Divergence is recorded as `DIVERGENT`, not `FAIL`. Expected field-level subtractions are documented in `expected_divergences.md`.

## Adversarial fixtures

Eight CVE/attack classes are implemented:

1. **CVE-2023-44487** (Rapid Reset) — h2 server sends HEADERS+RST_STREAM repeatedly
2. **CVE-2024-27919** (CONTINUATION flood) — unbounded CONTINUATION frames
3. **HPACK bomb** — header block decoding to 10MB
4. **HTTP/2 DoS family** — ping flood, settings flood, empty frames flood
5. **WINDOW_UPDATE accounting** — overflowing window updates
6. **DATA slowloris** — h1 server emits 1 byte every 5 seconds
7. **Decompression bomb** — gzip body expanding to 50MB
8. **GOAWAY churn** — repeated GOAWAY frames

h2 adversarial fixtures use TLS with ALPN `h2` negotiation so that `eta_http` exercises the actual h2 client path.

## Notes

- The suite is opt-in; `dune runtest` is unchanged.
- Divergent interop scenarios are recorded in `results/` for inspection.
- `@http-bench` is intentionally quick: it covers small/medium GET and POST body paths. The 100 MiB download correctness case remains in `@interop`; concurrent h2 stress is not part of the default bench alias.
- Stock nginx does not include the `echo` module, so `/echo` and `/reflect` endpoints return an empty body with status 200. Both `eta_http` and `curl` receive the same empty response, so differential testing still passes, but true body echo is only verified against Caddy.
- Server configs are embedded as OCaml strings in `lib/nginx.ml` and `lib/caddy.ml` and rendered to a per-run temp directory. No checked-in template files are used.
