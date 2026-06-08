# Error Model Results

Status: value returns, defects, detached failures, and typed results have
separate contracts.

## What Was Tested

The probes cover a successful worker return, a worker exception, a worker
exception after cancellation, a detached worker exception, and typed business
errors returned as `result`.

## Evidence

| Probe | Result |
| --- | --- |
| returns value | `verdict=ok` |
| raises exception | surfaced through Effet runtime as `Cause.Die` |
| raises after cancel | worker exception still observed |
| raises after detach | prototype recorded detached completion; exception is not delivered to a caller |
| typed error via result | `typed_error_preserved` |

## Consequence

The blocking API should treat worker exceptions as defects for normal submitted
jobs.

Typed business errors should remain ordinary values, preferably
`('a, 'e) result`, returned by the blocking callback.

Detached jobs need production logging or metric emission for exceptions. The
scratch prototype is intentionally not a final tracer.
