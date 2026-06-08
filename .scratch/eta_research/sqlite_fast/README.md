# SQLite Fast Connector Lab

This lab decides the first Eta SQL slice: a clean-room SQLite connector that is
fast, low-allocation, and shaped for Eta. It is not the query-builder/PPX
experiment.

## Decision Question

What connector architecture should Eta implement for SQLite before designing
the higher-level SQL authoring API?

The connector must:

- use SQLite through declared project dependencies, not host-global installs;
- keep Eta's boundary: applications own state, Eta owns effect description and
  interpretation;
- avoid ORM semantics;
- support explicit connections, prepared statements, parameter binding, row
  scanning, transactions, and structured SQLite errors;
- make allocations and copying measurable before the public API hardens;
- leave room for a later Drizzle-like OCaml query API without depending on it.

## Non-Goals

- The Drizzle-like OCaml query API, PPX, schema DSL, or migration DSL. That is
  the next experiment.
- PostgreSQL, MySQL, or networked database protocol design.
- Copying Riot's SQLite implementation. Riot is prior art for behavior and
  tests, not source material for this clean-room connector.
- Shipping a generic ORM, active record layer, or application state framework.

## Proof Obligations

| Obligation | Why it matters | Minimum fair evidence | Status |
| --- | --- | --- | --- |
| O1 toolchain | Native SQLite depends on headers, libsqlite3, C stubs, and OxCaml. | One command in the Nix/OxCaml shell proves pkg-config, headers, link, and a tiny query. | Proven by P0 |
| O2 low allocation scan | Connector speed depends on scanning rows without materializing avoidable lists/records. | Benchmark SELECT over many rows with wall time and allocation for each candidate. | Proven for direct typed scans, materialized-row baselines, existing sqlite3, and Caqti/sqlite. |
| O3 bind cost | Prepared statement hot paths need predictable parameter binding cost. | Benchmark repeated statement reuse with 0, 1, and N parameters. | Proven for direct stubs, existing sqlite3, and Caqti/sqlite. |
| O4 value decoding | A fast connector should not force every row through a broad boxed universal value. | Positive typed-column fixture plus an adversarial broad-value fixture. | Partial: typed-column positive fixture passes in P1; broad-value adversarial fixture remains P2/P3. |
| O5 lifecycle | Statements and connections must finalize exactly once under success and failure. | Runtime smoke for prepare/step/error/finalize/close and transaction rollback. | Proven for the direct-stub fixture by P1 and P3. |
| O6 Eta fit | The connector should integrate with Eta without turning Eta into an app framework. | Focused package API sketch and one Eta Runtime smoke after connector proof. | Proven for the first connector slice by Eta.Sqlite and package tests. |

## Hypothesis Ledger

| Candidate | Why plausible | Evidence needed to win | Evidence that would falsify it | Current status |
| --- | --- | --- | --- | --- |
| A. Direct libsqlite3 stubs with typed row scanner | Owns the hot path, can expose statement reuse, can avoid generic row allocation, and fits OxCaml experiments. | Beats or matches baselines on O2/O3 while passing lifecycle smoke. | C boundary overhead, copies, or unsafe lifetime rules dominate; lifecycle cannot be made robust. | Active; P1 positive fixture passes |
| B. Riot-like eager result materialization | Simple, tested prior art: execute fills a result object and fetch pops rows. Useful as a baseline and behavior reference. | Comparable allocations despite easier API, or much better lifecycle/error clarity. | Materializing rows/lists allocates too much on realistic scans. | Dominated as primary hot-path shape by P2 allocation evidence; still possible as optional convenience |
| C. Existing OCaml sqlite3 binding substrate | May already solve native safety and linking, reducing maintenance. | Builds under OxCaml and exposes enough control for low-allocation statement reuse. | API forces boxing/materialization or unavailable/unsuitable package under the OxCaml switch. | Dominated for the primary low-allocation hot path by P2 scan and bind evidence; still useful prior art |
| D. Caqti/sqlite substrate | Existing SQL abstraction may be good enough for first Eta SQL. | Provides competitive hot-path cost and clean lifecycle/error behavior. | Dependency/API overhead dominates, or the generic layer blocks low-allocation typed scans. | Dominated for primary hot path by P2 allocation and bind evidence; useful high-level API prior art |
| E. Query API first | A typed query surface could drive connector needs from user ergonomics. | Evidence that connector decisions cannot be made without query-DX constraints. | Connector hot path has independent measurable choices that should be settled first. | Deferred by scope |

## Proof Ladder

1. P0: prove SQLite dependency and C stub link in nix develop .#oxcaml.
2. P1: implement the smallest direct-stub positive fixture: open in-memory DB,
   create table, insert, select one row. Proven by p1_direct_smoke.
3. P2: implement baseline scan benchmarks for direct stubs, eager
   materialization, and available package substrates. Proven for direct,
   materialized, existing sqlite3, and Caqti/sqlite.
4. P3: add negative/lifecycle fixtures: invalid SQL, parameter mismatch,
   finalize twice, close with live statements, rollback after failed statement.
5. P4: after P2/P3, promote the smallest proven connector slice into
   packages/eta. Proven by Eta.Sqlite and test_eta_sqlite.

## First Commands

~~~sh
nix develop .#oxcaml -c pkg-config --modversion sqlite3
nix develop .#oxcaml -c dune build scratch/eta_research/sqlite_fast/p0_link_probe.exe
nix develop .#oxcaml -c dune build scratch/eta_research/sqlite_fast/p1_direct_smoke.exe
nix develop .#oxcaml -c dune build scratch/eta_research/sqlite_fast/p2_scan_bench.exe
nix develop .#oxcaml -c dune build scratch/eta_research/sqlite_fast/p2_sqlite3_scan_bench.exe
nix develop .#oxcaml -c dune build scratch/eta_research/sqlite_fast/p2_bind_bench.exe
nix develop .#oxcaml -c dune build scratch/eta_research/sqlite_fast/p2_caqti_bench.exe
nix develop .#oxcaml -c dune build scratch/eta_research/sqlite_fast/p3_failure_smoke.exe
nix develop .#oxcaml -c sh -lc './_build/default/scratch/eta_research/sqlite_fast/p0_link_probe.exe'
nix develop .#oxcaml -c sh -lc './_build/default/scratch/eta_research/sqlite_fast/p1_direct_smoke.exe'
nix develop .#oxcaml -c sh -lc './_build/default/scratch/eta_research/sqlite_fast/p2_scan_bench.exe 200000'
nix develop .#oxcaml -c sh -lc './_build/default/scratch/eta_research/sqlite_fast/p2_sqlite3_scan_bench.exe 200000'
nix develop .#oxcaml -c sh -lc './_build/default/scratch/eta_research/sqlite_fast/p2_bind_bench.exe 200000'
nix develop .#oxcaml -c sh -lc './_build/default/scratch/eta_research/sqlite_fast/p2_caqti_bench.exe 200000'
nix develop .#oxcaml -c sh -lc './_build/default/scratch/eta_research/sqlite_fast/p3_failure_smoke.exe'
~~~

The first command is the dependency gate. If it fails, update flake.nix before
adding connector code.
