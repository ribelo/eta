# Synchronous-interface matched rows (2026-08-05)

Frozen `bench/signal_compare` workloads, three nine-sample processes, one
pinned CPU, release profile. Medians per operation:

| Workload | Wall (ns) | Words | Pre-redesign (ns) | Pre-redesign (words) |
|---|---:|---:|---:|---:|
| eta_signal.changed.depth_1 | 481 | 334 | 11,002 | 8,795 |
| eta_signal.changed.depth_10 | 1,355 | 478 | 14,664 | 12,287 |
| eta_signal.changed.depth_100 | 15,017 | 2,530 | 72,341 | 49,043 |
| eta_signal.cutoff.depth_10 | 1,202 | 431 | 11,633 | 9,780 |
| eta_signal.dynamic.switch | 1,509 | 636 | 21,331 | 16,339 |
| eta_signal_map.data_change.10000 | 188,859 | 746 | 13,935,584 | 2,571,401 |
| eta_signal_map.data_change.100000 | 3,979,281 | 838 | 301,211,251 | 25,106,642 |
| eta_signal_map.membership_change.10000 | 189,259 | 1,001 | — | — |
| eta_signal_map.membership_change.100000 | 4,007,196 | 1,134 | — | — |
| eta_signal_map.child_change.10000 | 821,742 | 440 | 60,897,287 | 6,993,791 |
| eta_signal_map.child_change.100000 | 27,079,970 | 464 | 1,723,489,099 | 72,998,406 |

The Eta-only wall-time rule (candidate below the pinned pre-redesign median)
holds on every row. The frozen acceptance-matrix gates (1.20x matched wall,
layered allocation ceilings) are not met; the remaining gap is per-stabilize
kernel machinery owned by issues 13, 15, and 16. See issue 12's answer.
