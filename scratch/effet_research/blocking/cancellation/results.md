# Cancellation Results

Status: pending cancellation accepted; started cancellation is nonpreemptive.

## What Was Tested

The probes cover cancellation before start, cancellation after start,
cooperative user cancellation, and detach-after-cancel behavior.

## Evidence

| Probe | Result |
| --- | --- |
| pending cancellation | `cancelled_before_start=1` and the queued job did not run |
| started cancellation | started job still finished after about 40 ms |
| cooperative cancel handle | worker observed user cancel handle and exited |
| detach after cancel | caller returned in 45 us; detached job completed later |

## Consequence

The production contract should match Tokio-style blocking cancellation:

- queued work can be cancelled before it starts,
- started blocking work is not preempted,
- cooperative cancellation requires an explicit user-provided handle,
- detached work must emit errors through logging or metrics because no caller is
  waiting for the result.
