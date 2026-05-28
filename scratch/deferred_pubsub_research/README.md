# Deferred and Pubsub evidence lab

This supersedes the earlier prose-only note in this directory. The design
claims below are backed by a runnable OCaml probe.

## Question

Should Eta expose public Deferred and Pubsub modules, and what Pubsub
implementation shape is actually viable on Eta's current primitives?

## Artifacts

- runtime fixtures: [runtime_smoke.ml](runtime_smoke.ml)
- decision journal: [verdict.md](verdict.md)
- latest command output: [run.out](run.out)

## How to run

    nix develop -c dune exec scratch/deferred_pubsub_research/runtime_smoke.exe

The fixture implements:

- Deferred_probe over Eio.Promise.
- Pubsub_probe over Eta.Queue and Eta.Channel.
- Shared_hub_probe over a Pubsub-owned shared buffer with subscriber cursors.
- Raw_queue_candidate as a negative control.

## Evidence covered

Deferred:

- many awaiters receive the same first completion;
- second completion returns false and does not overwrite the first;
- failed completion replays to a late awaiter.

Pubsub:

- Unbounded fan-out broadcasts to current subscribers;
- the per-subscriber Channel probe can report Drop_new drops;
- Backpressure blocks a publisher until the slow subscriber receives;
- close wakes a blocked backpressure publisher;
- close_with_error drains buffered values before surfacing the typed close error;
- scoped subscription cleanup closes an escaped subscription handle on body
  success, body failure, and body cancellation;
- cancellation of a blocked Backpressure publish does not leave a stale waiter;
- naive per-subscriber Channel backpressure can partially deliver a canceled
  publish to one subscriber but not another;
- Shared_hub_probe keeps canceled Backpressure publish atomic across
  subscribers;
- Shared_hub_probe proves Backpressure waits until a lagging subscriber drains
  retained messages;
- Shared_hub_probe models Drop_new as the production global retained-message
  capacity policy;
- exposing raw Queue.t is a negative control: user code can close the active
  subscription queue, which is lifecycle control Pubsub should own.

## Current conclusion

Deferred is low-risk: implement a small Eta-owned typed one-shot wrapper.

Pubsub is viable, but the tested implementation shape is not raw Queue.t.
The latest negative fixture also shows that Backpressure should not be a naive
loop over per-subscriber Channels if publish is meant to be atomic across all
current subscribers.

The evidence supports an abstract subscription handle plus explicit overflow
policy:

    type overflow =
      | Unbounded
      | Drop_new of { capacity : int }
      | Backpressure of { capacity : int }

    type publish_result = {
      subscriber_count : int;
      dropped : int;
    }

Implementation result: Eta.Pubsub v1 is built as its own shared hub buffer with
subscriber cursors/refcounts and hub-level publisher waiters. It reuses the same
low-level techniques already used by Queue/Channel, such as Eio.Mutex and
Eio.Promise waiters, but it does not compose Pubsub out of public Queue/Channel
mailboxes for Backpressure.

Sliding, replay, publishAll, and static no-escape subscriptions remain unproven.
They should not be part of v1 based on this evidence.
