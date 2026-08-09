# Eta Crux and Bonsai benchmark report

Date: 2026-08-09

## Result

This run compares five shared incremental-computation scenarios. It does not
compare Eta transport or Bonsai rendering.

The steady-state Bonsai driver was faster and allocated less in all four
action scenarios. Eta Crux constructed a fresh stateful root faster and with
less allocation.

Do not combine these rows into one score. Each row measures a different graph
shape and operation boundary.

## Median time

| Workload | Eta Crux median (p95) | Bonsai median (p95) | Eta / Bonsai |
|---|---:|---:|---:|
| Changed scalar | 14.247 µs (15.148 µs) | 0.380 µs (0.392 µs) | 37.45 |
| Equal-model cutoff | 14.478 µs (14.996 µs) | 0.218 µs (0.234 µs) | 66.51 |
| Changed child, 1,000 keys | 1.814 ms (1.866 ms) | 0.533 µs (0.551 µs) | 3,405.62 |
| Changed child, 10,000 keys | 391.351 ms (398.612 ms) | 0.549 µs (0.570 µs) | 713,073.42 |
| Root construction and first output | 6.424 µs (6.488 µs) | 81.086 µs (92.903 µs) | 0.079 |

A ratio greater than `1` means that Eta took more time. For startup, Eta was
about 12.6 times faster.

## Median allocation

| Workload | Eta Crux words/op | Bonsai words/op | Eta / Bonsai |
|---|---:|---:|---:|
| Changed scalar | 3,322.02 | 459.01 | 7.24 |
| Equal-model cutoff | 3,264.02 | 449.01 | 7.27 |
| Changed child, 1,000 keys | 3,049,627 | 550.01 | 5,544.67 |
| Changed child, 10,000 keys | 300,463,772 | 568.01 | 528,975.77 |
| Root construction and first output | 4,508 | 53,577.81 | 0.084 |

For startup, Eta allocated about 11.9 times fewer words.

## Measurement protocol

- Eta source commit:
  `bcf5e83cc66a7c0bed2e2f13155feb8301623ad1`.
- Bonsai package: `v0.18~preview.130.100+614`.
- Both executables used `oxcaml-compiler.5.2.0minus38`.
- Each framework and workload has 32 measured samples.
- Each measured sample lasted at least 50 ms.
- The runner used five untimed warmups and an ABBA process order.
- Each adapter and workload had an independent calibrated operation count.
- `Gc.compact` ran before each measured sample.
- CPU 15 used the `performance` governor.
- The CPU was not kernel-isolated. Its SMT sibling was CPU 31.
- CPU frequency boost was enabled.

Calibrated operation counts:

| Workload | Eta Crux | Bonsai |
|---|---:|---:|
| Changed scalar | 4,096 | 262,144 |
| Equal-model cutoff | 4,096 | 393,216 |
| Changed child, 1,000 keys | 48 | 196,608 |
| Changed child, 10,000 keys | 1 | 196,608 |
| Root construction and first output | 12,288 | 2,560 |

Startup uses isolated operations. Each root is constructed and observed in its
own timed interval. Teardown runs outside that interval. The intervals are
summed into one sample.

## Semantic checks

Before measurement, both adapters passed the same checks:

- exact action and transition counts,
- one production-driver cycle and one observation per operation,
- the complete scalar output sequence,
- zero dependent projection executions for an equal model,
- one child visit for a keyed change,
- exact equality of the complete keyed output map during validation,
- exact startup output.

The timed keyed rows inspect only cardinality and the changed middle value.
This avoids adding a full map traversal to the timed operation.

One production-driver cycle means one `Root.advance` or one
`Bonsai_driver.flush`. It does not mean that the private engines perform the
same number of stabilization calls. The Bonsai production driver can perform
more than one stabilization inside one `flush`.

## Interpretation limits

The keyed rows include each framework's persistent-map and keyed-diff
implementation. The checks prove that one child was visited and one output row
changed. They do not identify which internal operation caused the measured
cost. That question requires separate profiling and is outside this comparison.

The 100,000-key row was not run. The 10,000-key Eta sample allocated about 300
million words per operation, so the larger row did not meet the benchmark's
resource-safety requirement.

Lifecycle replacement was excluded. Eta removal cancels a scoped job and can
settle asynchronously. Bonsai runs explicit deactivation and activation effects
during `trigger_lifecycles`. There is no neutral completion fence for a ratio.

Eta's output-delivery acknowledgement, transport, requests, telemetry,
serialization, and capacity controls were excluded because Bonsai has no
matching contract. Bonsai DOM, VDOM, browser, JavaScript, and Wasm work was
also excluded.

The host used frequency boost and no kernel-isolated CPU. Use the ratios as
evidence for this machine and package set, not as universal constants. The raw
samples permit a future run on an isolated, fixed-frequency host.

## Raw evidence

- Raw result:
  [`results/20260809T144132Z.json`](results/20260809T144132Z.json)
- Result SHA-256:
  `80d0ac9b55f836acb14eb87b869329e233a71e2b290dc4b3a3ae008a99d000ff`
- Samples: 320 across 10 framework/workload groups.
- The result records every installed opam package version, benchmark source
  hashes, GC metrics, semantic counters, operation counts, and host metadata.
