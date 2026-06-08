# Resource Class Results

Status: manual named pools accepted for v1.

## What Was Tested

The probes model DB-like short work competing with many FS/SDK-like blocking
jobs.

## Evidence

| Probe | DB completion time | Explanation |
| --- | --- | --- |
| shared pool | 503 ms | DB work waited behind 100 FS-like jobs |
| separate DB/FS pools | 2 ms | DB had independent capacity |
| shared pool with class limits | 2 ms | reserved capacity prevented starvation |

## Consequence

One global blocking pool is not enough.

Effet v1 should expose named/manual pools and allow call sites to choose the
pool for each blocking operation. Built-in resource-class sugar can wait until
the implementation has real users and repeated patterns.
