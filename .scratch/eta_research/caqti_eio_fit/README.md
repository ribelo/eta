# SQL-CQ — caqti-eio fit-for-Eta investigation

Decide whether caqti-eio is the right W-layer substrate for eta-sql, and if so,
in which integration shape.

## Hypothesis space

**H1 — Lazy wrap.** eta-sql consumes `Caqti_eio.Pool` directly. caqti owns
connection lifecycle, pooling, health, eviction. eta-sql adds the upper layers
(Statement DX, Migrator, transactions) over caqti's surface.

**H2 — Eta-Pool wrap.** eta-sql uses `Caqti_eio.connect` / `disconnect` inside
`Eta.Pool`. Eta owns lifecycle, pooling, observability, eviction, health
predicate. caqti is wire only. Matches the eta-http precedent: substrate
handles the wire; Eta primitives own consumer-visible behavior.

**Pivot fallback.** If both shapes fail their disproof tests, the W-layer
decision moves to pgx (pure-OCaml PG driver) or DIY wire — handled outside
this epic.

The favored candidate is **H2**. Popperian discipline requires H2 face its
harshest test (CQ-4 — cancellation under Eta.Pool) *before* deep H2-specific
investment. H1 gets a fair smoke (CQ-2). The disproof matrix is explicit per
probe.

## Disproof matrix (advance summary)

| Probe | Falsifies H1 if | Falsifies H2 if |
| --- | --- | --- |
| CQ-0 | caqti-eio fails to build under our toolchain | (same) |
| CQ-1 | API surface forces uncontainable leak through eta-sql | (same) |
| CQ-2 | caqti's Pool unsuitable shape (no health hook, no cancellation, etc.) | n/a |
| CQ-3 | n/a | `connect`/`disconnect` cannot be wrapped without forcing caqti's pool |
| CQ-4 | n/a | mid-call cancel poisons connections, leaks pool slots, or raises after-cancel |
| CQ-5 | caqti has no liveness primitive at all | Eta.Pool's `health_check` cannot drive caqti's liveness without escaping |
| CQ-6 | `Caqti_error.t` has lossy mapping to typed error tree | (same) |
| CQ-7 | savepoint/rollback semantics break under caqti's TX surface | rollback runs zero or twice under cancel-mid-tx |
| CQ-8 | streaming forces materialization, breaking eta-stream backpressure | iter_s cancellation leaks rows or fiber |
| CQ-9 | no seam to inject Tracer; spans require deep call-site changes | (same) |

A probe **must not** mark H1 or H2 rejected on proof-cost alone. Only fixture
failure, dominated-on-criteria, or external constraint. Untested aspects stay
visible as deferred.

## Decision criteria (cross-tabulated at epic close)

- Cancellation correctness (per CQ-4, CQ-7)
- Lifecycle ownership clarity (per CQ-3)
- Error mapping fidelity (per CQ-6)
- Observability seam (per CQ-9)
- Transaction-scoping correctness (per CQ-7)
- Streaming / cursor support (per CQ-8)
- Health predicate quality (per CQ-5)
- Dependency posture (libpq + libsqlite3 vs. pure-OCaml alternative)
- Code complexity at consumer call site
- Capability completeness (LISTEN/NOTIFY, COPY, prepared-stmt cache)

## Layout

```
caqti_eio_fit/
  README.md          - this file
  prior_art.md       - what we know from caqti's docs/source (CQ-1 input)
  api_audit.md       - CQ-1 deliverable: type story, seams, leaks
  cq0_install/       - install + build gate
  cq2_h1_smoke/      - lazy-wrap fixture
  cq3_h2_smoke/      - Eta.Pool around Caqti_eio.connect
  cq4_cancellation/  - mid-call cancel under H2 (the dagger)
  cq5_health/        - liveness predicate for Eta.Pool
  cq6_errors/        - Caqti_error → typed Cause mapping
  cq7_transactions/  - BEGIN/COMMIT/ROLLBACK under Supervisor.scoped
  cq8_streaming/     - cursors + eta-stream / Channel
  cq9_observability/ - Tracer integration
  results.md         - cross-tab + verdict
  adr.md             - decision record
```

Each `cqN_*/` subfolder gets created when the experimenter starts that probe;
each carries its own `README.md` with goal, fixtures, evidence requirement,
and pass criterion. Unstarted probes stay absent — directory presence
signals work-in-progress or done.

## Order of execution

```
0  install/build gate         (1-2h)
↓
1  API audit                  (1d)
↓
2  H1 smoke      ──────┐      (1-2d, parallel with 3)
3  H2 smoke   ─┐       │      (1-2d, parallel with 2)
              ↓        │
              4 cancellation under H2     ← Popperian dagger
              │
              ├── 5 health predicate          (parallel after 3)
              ├── 6 error mapping             (parallel after 3)
              ├── 7 transaction scoping       (parallel after 3)
              ├── 8 streaming/cursors         (parallel after 3)
              └── 9 observability/tracer      (parallel after 3)

→ Epic close: cross-tab in results.md, verdict in adr.md, V-SQL-Caqti journal.
```

CQ-4's verdict gates depth of H2-specific work in CQ-5 through CQ-9. If CQ-4
falsifies H2, those probes pivot to H1 (or hybrid) for the remaining evidence.

## Out of scope

- Building eta-sql.
- Designing Statement DX (PPX vs combinator vs plain string — separate question).
- Designing Migrator.
- Producing a final eta-sql public API.
- **All non-PG / non-SQLite databases.** MySQL, MariaDB, MSSQL, Oracle, etc.
  are not researched, not tested, not listed as gaps. Two backends only:
  PostgreSQL (volume anchor) and SQLite (per-driver assumption flush).

## Verdict shape

Epic close produces `adr.md` identifying one of:

- **H1** — lazy-wrap caqti's pool. eta-sql exposes its own surface but caqti's
  lifecycle wins.
- **H2** — Eta-Pool wraps caqti's connection. Eta owns lifecycle.
- **Hybrid** — caqti's pool for some shapes, Eta.Pool for others. Cited
  rationale per shape.
- **Pivot** — caqti unsuitable; W-layer choice escalates to pgx / direct
  libpq / DIY. Documented disproof per shape; new epic spawned.

Verdict is tied to evidence per criterion. Untested or partially-tested
criteria stay explicit in the journal, not silently elided.

## Dependencies and environment

The repo's `flake.nix` is the canonical install path for any dependency the
probes need. If something is missing, **extend `flake.nix`** rather than
apt-install or brew-install on the host.

Expected additions for this lab:

- `pkgs.postgresql` — local PG server for CQ-2 onward. Either run as a
  one-shot `pg_ctl initdb && pg_ctl start` inside the dev shell, or wire it
  as a `services.postgresql` style helper if more convenient.
- `pkgs.sqlite` (and headers) — usually present already; confirm in CQ-0.
- libpq headers if not pulled in transitively by `pkgs.postgresql`.
- opam packages: `caqti`, `caqti-eio`, `caqti-driver-postgresql`,
  `caqti-driver-sqlite3`. Pinned via the dev shell's opam switch
  (`.opam-oxcaml/` per `flake.nix`).

CQ-0's deliverable includes the diff to `flake.nix` and a one-command path
(documented in `cq0_install/README.md`) for the experimenter to bring up
postgres locally and run a connection smoke. No host-level installs.

## References

- caqti-eio: https://ocaml.org/p/caqti-eio/latest
- Pool methodology precedent: scratch/eta_research/pool_survival/results.md
- Channel methodology precedent: scratch/eta_research/channel_choice/results.md
- eta-http W-layer pivot precedent: scratch/eta_http_research/h_s3_pivot/
- Master objective context: .objectives/eta-otel-and-eta-ai.md (eta-sql is
  downstream from this work; not yet filed as a track of its own)
