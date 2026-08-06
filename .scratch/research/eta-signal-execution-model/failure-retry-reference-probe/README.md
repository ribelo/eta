# Eta Signal failure and retry reference probe

This throwaway probe measures the current Eta Signal engine.
It does not contain production Signal code.

The reference revision is `d04d6e2bedc87ab22326af5cc03c339406177a67`.
The `lib/` tree at `HEAD` has no difference from this revision.

## Graph

The graph has one integer variable.
The graph also has one watched signal and `depth` unary maps.
Each map adds one.

The depths are 1, 10, and 100.
Thus, the graph has 3, 12, or 102 graph objects.
The computation chain has 2, 11, or 101 signal nodes.

The failure row uses the last map at each depth.
The depth-10 row also uses the first map and map 5.
Map 5 is the middle position for this probe.

## Measured operations

One `failed_retry` operation does these actions:

1. Set the failure flag.
2. Set the source to a fresh integer.
3. Run one stabilization that raises `Probe_failure`.
4. Observe the defect result.
5. Clear the failure flag.
6. Run one successful stabilization.

The timed operation includes these actions.
The snapshot reads do not occur in the timed batch.

One `successful` operation sets the source to a fresh integer.
Then it runs one successful stabilization.

The probe retains private demand before measurement.
The probe also completes one warm-up batch before measurement.
The final read and demand release occur outside measurement.

## Layers

The `raw` layer holds one graph lane for the complete batch.
It uses `Var.set_unlocked` and `begin_stabilize`.
The defect branch checks that the cleanup-hook list is empty.
The atomic pass has already rolled back and requeued the source.
The retry calls `Graph.finish_stabilization` after the successful plan.

The `public_sync` layer uses public `Var.set` and `stabilize` effects.
It runs these effects on the synchronous runtime.
It observes the defect as an `Eta.Cause.Die` exit.

## Defect path

`begin_stabilize` installs staging rollback and source requeue at `eta_signal_kernel.ml:5554-5563`.
It runs the atomic pass at `eta_signal_kernel.ml:5565-5570`.

The atomic pass catches the exception at `eta_signal_atomic_pass.ml:308-317`.
Its rollback requeues the source and returns to idle at `eta_signal_atomic_pass.ml:228-241`.

The public shell stores cleanup hooks at `eta_signal_kernel.ml:5572-5578`.
It converts the defect to an Eta defect at `eta_signal_kernel.ml:5631-5637`.
Its exit handler runs pending cleanup at `eta_signal_kernel.ml:5643-5644`.

The raw defect branch observes the same atomic-pass result.
This scalar graph produces no cleanup hooks.
The probe stops if the hook list is not empty.
Thus, this workload needs no raw cleanup action.

## Correctness checks

Each process runs a correctness check before calibration.
The check reads the committed output after the failed pass.
The value must equal the value before the failed pass.

The check reads the output after the retry.
The value must equal the fresh source plus `depth`.

The raw result match must first use the defect branch.
The retry result match must then use the successful branch.
The next operation also proves that the graph returned to the idle state.

## Run the probe

Run the authoritative protocol from the repository root:

```sh
nix develop -c bash \
  .scratch/research/eta-signal-execution-model/failure-retry-reference-probe/run.sh
```

The default run uses CPU 2.
It uses nine samples and three comparison pairs.
Each workload runs in a fresh process.

Use this command for a provisional run:

```sh
CPU=8 SAMPLES=3 PAIRS=1 nix develop -c bash \
  .scratch/research/eta-signal-execution-model/failure-retry-reference-probe/run.sh
```

The script first builds `@install` with the release profile.
Then it exports `OCAMLPATH`.
It builds the separate Dune project with `-O3`.

The script writes `results.csv`.
This file contains each sample and a `pair` column.
The script also writes `summary.csv`.
This file contains the median for each process.

## Limits

The probe measures one demanded scalar chain.
It does not measure a graph with branches or shared nodes.
It does not measure dynamic binds or keyed nodes.
It does not measure graph errors.
It does not measure observer callbacks or observer failures.
It does not measure cleanup hooks.
It does not measure timers or timer rollback.
It does not measure disposal or demand transitions.
It does not measure lane acquisition or lane contention in the `raw` row.
It does not measure Eio runtime costs.
It does not measure multi-domain use.
It does not record affected-work counters.

Full ASD-STE100 compliance needs the official dictionary.
