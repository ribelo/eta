# C Stub Results

Status: B3 required for lock-holding C.

## What Was Tested

The C probes separate three cases:

- a C sleep that releases the OCaml runtime lock,
- a C sleep that holds the runtime lock,
- a C CPU loop that holds the runtime lock.

Each probe ran directly and through `Eio_unix.run_in_systhread`.

## Evidence

| Probe | Direct p99 | Systhread p99 | Verdict |
| --- | --- | --- | --- |
| release-lock sleep | 49085 us | 11 us | systhread works |
| hold-lock sleep | 49085 us | 49188 us | systhread does not help |
| hold-lock CPU | 52469 us | 52217 us | systhread does not help |

## Consequence

A normal systhread blocking pool cannot protect the Eio scheduler from C
bindings that keep the OCaml runtime lock.

Effet needs a separate, explicit domain-isolated pool for known or suspected
lock-holding bindings. The API should make this choice visible because it has
different cost and safety properties.
