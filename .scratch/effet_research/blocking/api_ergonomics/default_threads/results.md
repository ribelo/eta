# Default Thread Count Results

Status: `production_default = 128`.

This probe closes Effet-OxCaml-q73 for the V-Blocking-Impl epic. It measures
candidate defaults for the runtime-owned `Effect.Blocking` pool.

Run:

```sh
nix develop -c bash scratch/effet_research/blocking/api_ergonomics/default_threads/run.sh
```

Latest raw output:

```text
scratch/effet_research/blocking/api_ergonomics/default_threads/results.out
```

## Candidates

The host reported `Domain.recommended_domain_count () = 32`, so the CPU-based
candidates were:

| Candidate | max_threads |
| --- | --- |
| num_cpu / 2 | 16 |
| num_cpu | 32 |
| num_cpu * 2 | 64 |
| fixed 32 | 32 |
| fixed 128 | 128 |
| fixed 512 | 512 |

Tokio's `max_blocking_threads=512` reasoning is that blocking work is usually
I/O-bound: workers spend most of their time parked in syscalls, so the cap
should provide burst headroom and queue only after that cap. This matrix tests
that reasoning against Effet-sized workloads rather than copying the number.

## Workloads

| Workload | Shape |
| --- | --- |
| W1 | 100 jobs sleeping 50ms |
| W2 | 50 jobs sleeping 50ms plus 50 jobs doing about 5ms OCaml CPU |
| W3 | 100 `/tmp` stat/read/unlink jobs |

Selection budget: heartbeat p99 under 10ms, bounded peak threads, and wallclock
competitive with the next-larger fixed candidate.

## Matrix

| Candidate | Workload | Wallclock | Peak threads | Peak RSS | Heartbeat p99 | Recovery |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 16 | W1 | 351102 us | 18 | 11060 KB | 48 us | 1011 us |
| 16 | W2 | 398679 us | 18 | 12360 KB | 66663 us | 1001 us |
| 16 | W3 | 1424 us | 18 | 13808 KB | 50 us | 1011 us |
| 32 | W1 | 200911 us | 34 | 16224 KB | 55 us | 1002 us |
| 32 | W2 | 297135 us | 34 | 16568 KB | 61129 us | 1000 us |
| 32 | W3 | 1453 us | 34 | 18220 KB | 99 us | 1009 us |
| 64 | W1 | 101529 us | 66 | 19404 KB | 88 us | 1003 us |
| 64 | W2 | 251490 us | 66 | 19336 KB | 74133 us | 1006 us |
| 64 | W3 | 2212 us | 66 | 21300 KB | 41 us | 1000 us |
| fixed 32 | W1 | 201042 us | 34 | 20088 KB | 47 us | 1012 us |
| fixed 32 | W2 | 300471 us | 34 | 19356 KB | 69521 us | 1001 us |
| fixed 32 | W3 | 1727 us | 34 | 20560 KB | 143 us | 1001 us |
| fixed 128 | W1 | 51324 us | 102 | 21216 KB | 147 us | 1012 us |
| fixed 128 | W2 | 300804 us | 102 | 20976 KB | 341 us | 1011 us |
| fixed 128 | W3 | 2068 us | 102 | 22332 KB | 526 us | 1000 us |
| fixed 512 | W1 | 51654 us | 102 | 22000 KB | 38 us | 1012 us |
| fixed 512 | W2 | 301088 us | 102 | 21188 KB | 421 us | 1010 us |
| fixed 512 | W3 | 6307 us | 102 | 21836 KB | 587 us | 1000 us |

## Verdict

`production_default = 128`.

`num_cpu / 2`, `num_cpu`, `num_cpu * 2`, and fixed 32 fail the mixed workload
heartbeat budget on this host: W2 p99 ranged from about 61ms to 74ms.

Fixed 128 and fixed 512 both meet the heartbeat budget across W1-W3. Fixed 128
is the smaller cap, has the same effective peak thread count in this 100-job
matrix, is equal or better on W2/W3 wallclock, and avoids advertising Tokio's
512 headroom without evidence that Effet needs it.

Use `max_queued = 64`, `queue_policy = Wait`, and `shutdown_policy = Drain` for
the runtime-owned default pool. Applications with known higher blocking I/O
concurrency should configure an explicit pool; 128 is a measured starting point,
not a universal ceiling.
