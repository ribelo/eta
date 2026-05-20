---
id: Effet-zen
title: Resource.auto with background refresh fiber
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T14:24:12.675Z
created_by: backlog
updated_at: 2026-05-19T15:03:45.186Z
closed_at: 2026-05-19T15:03:45.186Z
close_reason: Implemented Resource.auto with scheduled background refresh via
  runtime-owned detach/fork_internal, preserves last-good value on refresh
  failure with optional on_error hook, added virtual-clock tests for refresh and
  failure recovery, and nix develop -c dune runtest --force passes.
dependencies:
  - issue_id: Effet-zen
    depends_on_id: Effet-5bs
    type: blocks
    created_at: 2026-05-19T14:24:28.588Z
    created_by: backlog
---

# Resource.auto with background refresh fiber

## description

packages/effet/resource.ml ships only Resource.manual (loader-on-first-get with explicit refresh). Resource.auto was deferred from journal section ~376 onward, with reasoning: 'Effect-TS Resource.auto can fork a managed background refresh fiber directly; Apsis does not currently expose a public fork/start primitive inside Effect.t. Auto-refresh should probably be expressed later as a subscription or a runtime-managed resource.' Now unblocked by Effect.detach and the upcoming fork_internal helper.

## design

Resource.auto : load:('env, [> `Refresh_failed of string ], 'a) Effect.t -> schedule:Schedule.t -> ('env, _, 'a Resource.t) Effect.t. Implementation: scoped effect that runs the loader once synchronously to seed the cache, then forks a daemon via fork_internal that loops {sleep per schedule; rerun loader; on Ok update cache atomically; on Error keep last-good value, optionally call ?on_error}. Daemon is owned by the runtime's outer switch and stops cleanly on runtime teardown. Cache uses Atomic.t for cross-fiber visibility. Resource.get on the auto resource returns the latest cached value without forcing a refresh. Optional ?on_error : 'err -> unit hook for observability. Use Schedule.exponential or Schedule.spaced for the refresh cadence.

## acceptance criteria

Resource.auto returns a resource whose get reads the latest cached value. A test using Test_clock advances virtual time through 3 refresh cycles and asserts Resource.get returns the freshest loader result after each cycle. A test where one refresh fails (loader returns Cause.Fail) verifies the previous cached value is preserved and subsequent successful refreshes resume updating. A test verifies the daemon stops when the runtime's outer switch is closed (no leaked fibers). Existing Resource tests continue to pass.
