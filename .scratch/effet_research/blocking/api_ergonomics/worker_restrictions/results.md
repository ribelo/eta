# Worker Restriction Results

Status: worker callbacks must be boring synchronous functions.

## What Was Tested

The probes attempted same-domain and Eio operations from inside blocking worker
callbacks.

## Evidence

| Probe | Observed | Contract |
| --- | --- | --- |
| `Eio.Stream.add` | `added` | unsupported in v1 |
| nested `Runtime.run` | `ok:1` | unsupported in v1 |
| nested blocking submit | `Stdlib.Effect.Unhandled(Eio__core__Cancel.Get_context)` | reject or undefined in v1 |
| resolving parent promise | `worker_returned:resolved` | unsupported in v1 |

## Consequence

The production API must not infer support from simple probes that happened to
work. Worker callbacks should not use Eio, call Effet runtimes, submit nested
blocking work, or interact with parent-domain synchronization objects.

Keep the v1 contract simple: a blocking worker is a synchronous OCaml function
that returns a value or raises.
