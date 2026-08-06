# Generic value-storage probe

**PROTOTYPE:** This directory contains throwaway research code. It does not
contain production Signal code.

## Representations

- Candidate A stores `current`, `undo`, and the write stamp in a typed node.
  The arena stores `Node : 'a node -> packed`.
- Candidate B stores values as `Obj.t` in one flat node. All casts stay inside
  the candidate module.
- Candidate C stores values in a typed cell. A packed record contains retained
  evaluation, rollback, and stamp closures.

All candidates use the accepted direct unary propagation path, retained height
buckets, a sparse immediate integer journal, an O(1) value-journal commit,
reverse rollback, and a retained admission frontier.

The probe checks heterogeneous `int`, `string`, and record nodes. It also checks
same-typed rollback, boxed physical identity, failure and retry, immediate
journal entries, and four-word allocation at depths 1, 10, and 100.

## Run

Run the authoritative release suite from the repository root:

```sh
nix develop -c bash \
  .scratch/research/eta-signal-execution-model/generic-value-storage-probe/run.sh
```

The default run uses CPU 2, nine samples, three process pairs, calibration from
one operation to 0.5 seconds or 16,777,216 operations, and one fresh process for
each workload. It writes `results.csv` and `summary.csv`.

Use this command for a one-sample, one-pair smoke run:

```sh
SAMPLES=1 PAIRS=1 nix develop -c bash \
  .scratch/research/eta-signal-execution-model/generic-value-storage-probe/run.sh
```

## Measurement boundaries

The changed rows include one source write and one stabilization. Setup, graph
construction, promotion, warm-up, the final read, and teardown stay outside the
measured operation.

Immediate integer and boxed-old rows use values that do not allocate during
propagation. The fresh boxed row constructs one young record during each
operation. These controls separate the costs:

- `control.boxed_young.construct` constructs and consumes one young record.
- `control.boxed_old.old_ref_store` writes alternating promoted records to a
  promoted reference.
- `control.boxed_young.old_ref_store` constructs a young record and writes it to
  a promoted reference.

The difference between the construction-only and young old-reference rows
estimates one old-to-young store and remembered-set cost. It is not a runtime
write-barrier symbol count. Candidate rows perform several value stores, so the
controls support attribution but do not provide exact per-barrier subtraction.

The `control.int` rows use an integer-specialized kernel with no existential,
`Obj.t`, typed cell, or packed value closures. It retains the same scheduler and
rollback shape as the candidates. It is a broad lower bound, not a one-factor
value-representation control.

These standalone rows are prototype evidence. Issue 11 owns the final run in
the frozen comparison harness.
