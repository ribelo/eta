# SQLite Fast Connector Results

## Current Status

Status: P4 first Eta.Sqlite connector slice promoted.

The experiment branch exists and the dependency gate found that the OxCaml
shell was missing SQLite. flake.nix now declares pkgs.sqlite in the shared
OxCaml host package list. The C-stub link probe now builds and runs against
SQLite 3.51.2 from Nix. The direct-stub connector fixture passes the first
prepare/bind/step/finalize smoke and the failure/lifecycle smoke. Scan and
bind benchmarks compare direct typed stubs against materialized rows, the
existing sqlite3 package, and Caqti/sqlite. The first production slice is now
promoted as Eta.Sqlite: explicit database handles, prepared statements, typed
binds and column reads, structured result errors, file/in-memory opening, and
SQLite lifecycle tests.

## Evidence Artifacts

| Artifact | Purpose | Status |
| --- | --- | --- |
| README.md | Decision question, proof obligations, hypothesis ledger, proof ladder. | Written |
| flake.nix | Declares SQLite dependency, sqlite3 package baseline, and Caqti research packages for the OxCaml setup path. | Updated |
| dune, p0_sqlite.ml, p0_sqlite_stubs.c, p0_link_probe.ml | P0 C-stub link and in-memory SQLite query. | Passing |
| direct_sqlite.ml, direct_sqlite_stubs.c, p1_direct_smoke.ml | P1 direct-stub connector fixture. | Passing |
| p2_scan_bench.ml | Direct typed scan vs materialized-row allocation benchmark. | Passing for A vs B |
| p2_sqlite3_scan_bench.ml | Existing sqlite3 package typed scan and materialized-row benchmark. | Passing for C |
| p2_bind_bench.ml | Direct stubs vs sqlite3 prepared-statement reuse with 0, 1, and 8 params. | Passing |
| p2_caqti_bench.ml | Caqti/sqlite scan fold, collection, and 0/1/8-param request benchmark. | Passing for D |
| p3_failure_smoke.ml | Bind range, constraint failure/reset recovery, closed DB, invalid SQL recovery. | Passing |
| packages/eta/sqlite.ml, sqlite.mli, sqlite_stubs.c | First promoted Eta SQLite connector slice. | Passing package tests |
| packages/eta/test/test_eta_sqlite.ml | Public package smoke, lifecycle, structured error, file/read-only, and Eta Runtime tests. | Passing |

## Commands And Results

~~~sh
git switch -c research/sqlite-fast
~~~

Result:

~~~text
Switched to a new branch 'research/sqlite-fast'
~~~

~~~sh
nix develop .#oxcaml -c sh -lc 'pkg-config --modversion sqlite3 && command -v sqlite3 && sqlite3 --version'
~~~

Result before dependency patch:

~~~text
Package sqlite3 was not found in the pkg-config search path.
No package 'sqlite3' found
~~~

~~~sh
nix develop .#oxcaml -c sh -lc 'pkg-config --modversion sqlite3 && command -v sqlite3 && sqlite3 --version'
~~~

Result after dependency patch:

~~~text
3.51.2
/nix/store/67cm7qx8s210dwkq64vqbf3q9z62ddyg-sqlite-3.51.2-bin/bin/sqlite3
3.51.2 2026-01-09 17:27:48 b270f8339eb13b504d0b2ba154ebca966b7dde08e40c3ed7d559749818cbalt1 (64-bit)
~~~

~~~sh
nix develop .#oxcaml -c dune build scratch/eta_research/sqlite_fast/p0_link_probe.exe
nix develop .#oxcaml -c sh -lc './_build/default/scratch/eta_research/sqlite_fast/p0_link_probe.exe'
~~~

Result:

~~~text
sqlite_version=3.51.2
p0_sqlite_smoke=count:1
~~~

~~~sh
nix develop .#oxcaml -c dune build scratch/eta_research/sqlite_fast/p0_link_probe.exe scratch/eta_research/sqlite_fast/p1_direct_smoke.exe
nix develop .#oxcaml -c sh -lc './_build/default/scratch/eta_research/sqlite_fast/p0_link_probe.exe && ./_build/default/scratch/eta_research/sqlite_fast/p1_direct_smoke.exe'
~~~

Result:

~~~text
sqlite_version=3.51.2
p0_sqlite_smoke=count:1
p1_direct_smoke PASS
~~~

P1 coverage:

- in-memory database open/close;
- DDL and insert execution through prepared statements;
- statement reuse through reset and clear_bindings;
- parameter count and typed int/text binding;
- typed int/text column access without generic row materialization;
- transaction rollback;
- invalid SQL prepare failure;
- finalize twice;
- reset after finalize returning SQLITE_MISUSE;
- close with a live statement followed by explicit statement finalization.

Baseline availability:

~~~text
ocamlfind query sqlite3 -> .opam-oxcaml/5.2.0+ox/lib/sqlite3
ocamlfind query caqti -> .opam-oxcaml/5.2.0+ox/lib/caqti
ocamlfind query caqti-driver-sqlite3 -> .opam-oxcaml/5.2.0+ox/lib/caqti-driver-sqlite3
installed packages: sqlite3 5.4.1, caqti 2.3.0, caqti-driver-sqlite3 2.3.0, caqti-eio 2.3.0
~~~

~~~sh
nix develop .#oxcaml -c dune build scratch/eta_research/sqlite_fast/p2_scan_bench.exe
nix develop .#oxcaml -c sh -lc './_build/default/scratch/eta_research/sqlite_fast/p2_scan_bench.exe 200000'
~~~

Representative result:

~~~text
direct_int_sum rows=200000 result=20000300000 wall_ms=13.714 allocated_bytes=128 minor_words=0 promoted_words=0 major_words=0 minor_collections=0 major_collections=0
eager_int_rows rows=200000 result=20000100000 wall_ms=13.972 allocated_bytes=4800128 minor_words=0 promoted_words=0 major_words=0 minor_collections=0 major_collections=0
direct_pair_sum rows=200000 result=20002188895 wall_ms=20.954 allocated_bytes=4799336 minor_words=0 promoted_words=0 major_words=0 minor_collections=0 major_collections=0
eager_pair_rows rows=200000 result=20002188895 wall_ms=24.235 allocated_bytes=14399336 minor_words=1048576 promoted_words=1048576 major_words=1048576 minor_collections=1 major_collections=0
~~~

Interpretation:

- Direct integer scans are effectively allocation-free at this scale: 128 bytes
  for the measured query wrapper path.
- Materializing integer rows forces about 4.8 MB for 200k rows when rows escape
  through a global sink, which is the relevant boundary for a result-object API.
- Text decoding allocates string copies either way. The direct int+text scan
  allocates about 4.8 MB; materializing the same rows allocates about 14.4 MB.
- Wall-time differences are modest for integer-only scans and visible for
  int+text scans. The decisive current signal is allocation, not time.
- Gc.allocated_bytes is the primary allocation metric for this benchmark.
  Gc.quick_stat word fields can stay flat until collection boundaries and can
  be misleading for smaller runs.

Existing sqlite3 package scan baseline:

~~~text
sqlite3_direct_int_sum rows=200000 result=20000300000 wall_ms=13.101 allocated_bytes=4800104 minor_words=0 promoted_words=0 major_words=0 minor_collections=0 major_collections=0
sqlite3_eager_int_rows rows=200000 result=20000100000 wall_ms=15.062 allocated_bytes=9600104 minor_words=1048576 promoted_words=524305 major_words=0 minor_collections=1 major_collections=0
sqlite3_direct_pair_sum rows=200000 result=20002188895 wall_ms=19.725 allocated_bytes=9599312 minor_words=1048576 promoted_words=37 major_words=0 minor_collections=1 major_collections=0
sqlite3_eager_pair_rows rows=200000 result=20002188895 wall_ms=24.003 allocated_bytes=19199312 minor_words=2097148 promoted_words=1572844 major_words=786415 minor_collections=2 major_collections=0
~~~

Bind/reuse benchmark:

~~~text
direct_zero_param iterations=200000 result=200000 wall_ms=27.865 allocated_bytes=128 minor_words=0 promoted_words=0 major_words=0 minor_collections=0 major_collections=0
sqlite3_zero_param iterations=200000 result=200000 wall_ms=33.374 allocated_bytes=4800104 minor_words=0 promoted_words=0 major_words=0 minor_collections=0 major_collections=0
direct_one_param iterations=200000 result=20000100000 wall_ms=31.915 allocated_bytes=128 minor_words=0 promoted_words=0 major_words=0 minor_collections=0 major_collections=0
sqlite3_one_param iterations=200000 result=20000100000 wall_ms=36.772 allocated_bytes=4800104 minor_words=0 promoted_words=0 major_words=0 minor_collections=0 major_collections=0
direct_eight_param iterations=200000 result=20007100000 wall_ms=82.142 allocated_bytes=128 minor_words=0 promoted_words=0 major_words=0 minor_collections=0 major_collections=0
sqlite3_eight_param iterations=200000 result=20007100000 wall_ms=92.962 allocated_bytes=4800104 minor_words=0 promoted_words=0 major_words=0 minor_collections=0 major_collections=0
~~~

Caqti/sqlite scan and bind benchmark:

~~~text
caqti_fold_int_sum rows=200000 result=20000300000 wall_ms=34.263 allocated_bytes=25603528 minor_words=3145727 promoted_words=189 major_words=186 minor_collections=3 major_collections=0
caqti_collect_int_rows rows=200000 result=20000100000 wall_ms=38.133 allocated_bytes=35202720 minor_words=4194301 promoted_words=973514 major_words=579569 minor_collections=5 major_collections=2
caqti_fold_pair_sum rows=200000 result=20002188895 wall_ms=43.340 allocated_bytes=56002888 minor_words=6291452 promoted_words=245 major_words=245 minor_collections=6 major_collections=0
caqti_collect_pair_rows rows=200000 result=20002188895 wall_ms=54.032 allocated_bytes=65602176 minor_words=7340011 promoted_words=1738470 major_words=1738470 minor_collections=9 major_collections=4
caqti_zero_param iterations=200000 result=200000 wall_ms=161.321 allocated_bytes=585600872 minor_words=72351412 promoted_words=4787 major_words=4787 minor_collections=70 major_collections=1
caqti_one_param iterations=200000 result=20000100000 wall_ms=170.259 allocated_bytes=614401152 minor_words=76545753 promoted_words=5598 major_words=5502 minor_collections=74 major_collections=1
caqti_eight_param iterations=200000 result=20007100000 wall_ms=281.230 allocated_bytes=1124802648 minor_words=139984585 promoted_words=18602 major_words=18602 minor_collections=135 major_collections=3
~~~

Caqti interpretation:

- Caqti fold is a useful high-level baseline, but it is not a primary
  low-allocation substrate for Eta's SQLite hot path: integer scan fold
  allocates about 25.6 MB at 200k rows versus 128 bytes for direct stubs.
- Caqti's repeated request path allocates about 586 MB, 614 MB, and 1.12 GB for
  0, 1, and 8 parameter loops at 200k iterations. That is two orders of
  magnitude away from the direct-stub fixture.
- The Caqti/sqlite driver is implemented on top of the sqlite3 package, so it
  remains relevant as API prior art and for non-hot convenience semantics, not
  as the connector core for this experiment.

Failure/lifecycle smoke:

~~~text
p3_failure_smoke PASS
~~~

P3 coverage:

- out-of-range bind indexes return SQLITE_RANGE;
- duplicate UNIQUE insert returns SQLITE_CONSTRAINT;
- reset after failed step preserves the failure code and then permits recovery;
- closed database prepare fails at a controlled boundary;
- invalid SQL does not poison later valid work.

Promoted package gate:

~~~text
nix develop .#oxcaml -c dune runtest packages/eta/test --force
Result: eta-log-level passed 7 tests; eta passed 223 tests, including 6 Sqlite tests.

nix develop .#oxcaml -c dune build --profile release packages/eta
Result: passed.

nix develop .#oxcaml -c dune build scratch/eta_research/sqlite_fast/p0_link_probe.exe scratch/eta_research/sqlite_fast/p1_direct_smoke.exe scratch/eta_research/sqlite_fast/p2_scan_bench.exe scratch/eta_research/sqlite_fast/p2_sqlite3_scan_bench.exe scratch/eta_research/sqlite_fast/p2_bind_bench.exe scratch/eta_research/sqlite_fast/p2_caqti_bench.exe scratch/eta_research/sqlite_fast/p3_failure_smoke.exe
Result: passed.
~~~

## Cross-Tab

Filled after P2/P3.

| Criterion | A direct stubs | B eager materialization | C ocaml-sqlite3 | D caqti/sqlite | Citation |
| --- | --- | --- | --- | --- | --- |
| Scan wall time | 13.1ms int / 19.6ms int+text at 200k rows | 13.2ms int / 23.2ms int+text at 200k rows | 13.1ms int / 19.7ms int+text at 200k rows | 34.3ms int fold / 43.3ms int+text fold at 200k rows | p2_scan_bench + p2_sqlite3_scan_bench + p2_caqti_bench 200k |
| Scan allocation | 128 bytes int / 4.8MB int+text | 4.8MB int / 14.4MB int+text | 4.8MB int / 9.6MB int+text | 25.6MB int fold / 56.0MB int+text fold at 200k rows | p2_scan_bench + p2_sqlite3_scan_bench + p2_caqti_bench 200k |
| Bind/reuse cost | 27.9/31.9/82.1ms and 128 bytes for 0/1/8 params at 200k iterations | n/a | 33.4/36.8/93.0ms and 4.8MB for 0/1/8 params at 200k iterations | 161.3/170.3/281.2ms and 585.6MB/614.4MB/1.12GB for 0/1/8 params at 200k iterations | p2_bind_bench + p2_caqti_bench |
| Lifecycle safety | P1/P3 pass: finalize twice, close with live stmt, range, constraint, invalid SQL recovery | Not directly tested | Existing package has mature lifecycle API but not tested here | Caqti has mature connection/request lifecycle, but hot-path cost dominates for connector core | p1_direct_smoke, p3_failure_smoke, Caqti interfaces |
| Error clarity | Raw SQLite rc names are available; public error shape still needs design | n/a | Existing package exposes SQLite rc values | Caqti has rich typed errors and sqlite-specific details | direct_sqlite.ml, caqti_driver_sqlite3.mli |
| Eta boundary fit | Explicit DB/statement API fits connector-first Eta boundary | Optional convenience only | Useful fallback/prior art, but dependency owns hot path | Good high-level SQL abstraction, but too much for Eta's connector core | README decision question |
| Dependency cost | libsqlite3 via Nix plus Eta-owned stubs | same as A | opam sqlite3 package plus libsqlite3 | caqti + caqti-driver-sqlite3 + sqlite3 deps | flake.nix, ocamlfind query |

## Decision Diary

Connector-core verdict: direct typed stubs lead. The first Eta.Sqlite package
slice is promoted; the higher-level query authoring API remains deferred.

V-SQLite-0 - Start connector-first.
Decision: Defer the Drizzle-like query API/PPX until the connector hot path has
direct evidence.
Evidence: The current uncertainty is native SQLite ownership, row scanning,
binding, finalization, and allocation. Those are measurable without a query DSL.
Counterevidence considered: A query API could influence typed decoding. The lab
keeps O6 and Candidate E visible so that evidence can overturn the sequencing.
Confidence: Medium.
Would change if: P1/P2 shows connector shape cannot be judged without generated
typed query code.

V-SQLite-1 - Declare SQLite in the Nix/OxCaml shell.
Decision: Add pkgs.sqlite to flake.nix before connector code.
Evidence: The initial dependency gate failed with missing sqlite3 pkg-config
metadata. After adding pkgs.sqlite, pkg-config, the sqlite3 CLI, C compilation,
linking, and an in-memory query all pass in nix develop .#oxcaml.
Counterevidence considered: The host may have SQLite installed, but relying on
host-global headers would make the lab non-reproducible.
Confidence: High.
Would change if: A future Nixpkgs SQLite packaging change requires splitting
headers, library, and CLI packages.

V-SQLite-2 - Keep direct typed stubs alive for P2.
Decision: Candidate A remains active after P1.
Evidence: direct_sqlite exposes a small C-stub surface with untagged rc/index
arguments, unboxed int64 column/bind operations, runtime-lock release around
sqlite3_step, explicit reset/clear/finalize, and typed column reads. The P1
smoke passes success, rollback, invalid SQL, and lifecycle edge checks.
Counterevidence considered: P1 does not measure allocation or compare against
materialized row APIs. It only proves viability, not superiority.
Confidence: Medium.
Would change if: P2 shows the C boundary or lifecycle wrapper allocates enough
to lose against the boring existing binding or a Riot-like materialized result.

V-SQLite-3 - Do not make materialized rows the primary connector hot path.
Decision: Keep direct typed statement scanning as the primary candidate; treat
materialized rows as a convenience layer, if it exists at all.
Evidence: p2_scan_bench at 200k rows reports direct_int_sum at 128 allocated
bytes versus eager_int_rows at about 4.8 MB. For int+text scans, direct scanning
allocates about 4.8 MB for text copies while eager materialization allocates
about 14.4 MB. The benchmark forces eager rows to escape through a global sink
so OxCaml cannot stack-allocate away the result object boundary.
Counterevidence considered: The benchmark has not compared against the
existing sqlite3 package or Caqti/sqlite, and it does not yet isolate bind cost.
Confidence: Medium for A over B as the primary hot path; Low for final
connector architecture.
Would change if: an existing package substrate matches the allocation profile
while providing better lifecycle/error semantics, or if generated typed query
code needs a different scanner protocol.

V-SQLite-4 - Existing sqlite3 is not the primary low-allocation substrate.
Decision: Continue with Eta-owned direct stubs as the primary SQLite connector
candidate instead of building Eta SQL directly on the existing sqlite3 package.
Evidence: sqlite3 package typed scans have similar wall time but allocate much
more on hot paths: 4.8 MB for integer scans versus 128 bytes for direct stubs at
200k rows, and 4.8 MB for 0/1/8-param reuse loops versus 128 bytes for direct
stubs. The direct-stub path also wins wall time in the bind benchmark.
Counterevidence considered: sqlite3 is mature, broad, and already handles many
SQLite features. That remains valuable prior art and possible fallback for
non-hot convenience APIs.
Confidence: Medium.
Would change if: direct stubs become unsafe or costly to maintain, or if a
future generated query path can avoid sqlite3 package allocation without owning
stubs.

V-SQLite-5 - Keep Caqti deferred, not rejected.
Decision: Do not reject Caqti/sqlite yet.
Evidence: Caqti packages are installed and declared for the research shell, but
no P2/P3 Caqti fixture has been run in this lab.
Counterevidence considered: The generic Caqti API is likely to allocate more
than direct typed stubs, but that is a hypothesis until measured.
Confidence: Low after V-SQLite-6 superseded this deferred state.
Would change if: a focused Caqti/sqlite scan and bind fixture shows competitive
allocation with better lifecycle/error behavior.

V-SQLite-6 - Do not use Caqti/sqlite as the connector core.
Decision: Keep Eta-owned direct stubs as the connector-core candidate and use
Caqti as high-level API prior art only.
Evidence: p2_caqti_bench at 200k rows reports Caqti fold integer scan at about
25.6 MB allocated and 34.3ms, compared with 128 bytes and about 13ms for direct
stubs. Repeated Caqti find loops allocate about 586 MB, 614 MB, and 1.12 GB for
0, 1, and 8 parameters, compared with 128 bytes on the direct-stub fixture.
Counterevidence considered: Caqti provides mature request typing, lifecycle,
and error semantics, and it may remain useful as API inspiration for the later
query-authoring experiment.
Confidence: High for not using Caqti on the connector hot path; Medium for the
final public connector shape.
Would change if: Eta's future query API values Caqti compatibility above the
low-allocation SQLite hot path, or if Caqti gains a direct zero-allocation
scanner path under OxCaml.

V-SQLite-7 - Promote the first direct-stub connector slice.
Decision: Add Eta.Sqlite as an explicit low-level connector module rather than
waiting for the Drizzle-like query API.
Evidence: P2/P3 show direct typed stubs are the only candidate with the desired
hot-path allocation profile. The promoted module exposes file and in-memory
opening, prepared statements, reset/clear/finalize, typed int/int64/text bind
and column functions, SQLite rc values, structured result errors, and
convenience exec/query_one_int helpers. Package tests cover the direct smoke,
prepare errors, range and constraint errors, close with live statements,
read-only path opening, and an Eta Runtime smoke.
Counterevidence considered: The public shape is still low-level and not the
final ergonomic SQL API. Keeping it connector-level prevents the API experiment
from being prejudged.
Confidence: Medium.
Would change if: later query-generation evidence needs a different scanner
protocol, or if broader SQLite type coverage forces an incompatible statement
API.

## Deferred Work

- Query authoring API: Drizzle-like OCaml surface, PPX, schema and migration
  design.
- Non-SQLite backends.
- Broader SQLite type coverage: blobs, floats, null decoding, named parameters,
  busy timeout, and richer extended error codes.
