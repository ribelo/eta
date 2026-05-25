---
id: Eta-4s3
title: "P1: Channel.recv loses messages on cancellation race with delivery"
status: open
priority: 1
issue_type: bug
created_at: 2026-05-24T12:50:24.419Z
created_by: backlog
updated_at: 2026-05-24T12:50:34.763Z
dependencies:
  - issue_id: Eta-4s3
    depends_on_id: Eta-4ob
    type: parent-child
    created_at: 2026-05-24T12:50:30.191Z
    created_by: backlog
  - issue_id: Eta-4s3
    depends_on_id: Eta-lo9
    type: blocks
    created_at: 2026-05-24T12:50:34.763Z
    created_by: backlog
---

# P1: Channel.recv loses messages on cancellation race with delivery

## description

Bug: In Channel.recv (channel.ml:214-235), a sender calls take_receiver which marks receiver inactive and resolves its promise with `Item value`. If the receiving fiber is cancelled between the promise resolution and Eio.Promise.await returning to user code, cancel_receiver (channel.ml:162-166) sees active=false and does nothing. The message is lost — it left the buffer/send path but no caller receives it.

Location: packages/eta/channel.ml:53-81, 114-135, 214-235

## design

Same two-phase handoff as Semaphore. Delivery remains reclaimable until the waiting receiver claims it. States: Waiting | Delivered_unclaimed | Claimed | Cancelled. Receiver cancellation during Delivered_unclaimed returns the item to the buffer or wakes next receiver. Alternative: document Channel as at-most-once with possible loss under cancellation (makes it unsuitable as a general primitive).

RED test: channel with capacity=1, sender sends item to waiting receiver, cancel receiver between delivery and claim, assert item either in buffer or delivered to next receiver (never lost).

## acceptance criteria

RED test passes: no silent message loss. Existing channel tests pass unchanged. Pool and h2 multiplexer (Channel consumers) unaffected.
