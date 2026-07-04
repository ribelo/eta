---
kind: requirement
status: draft
tags: [eta_crux, subscriptions, streams]
refines: ["[[docs/requirements/eta-crux/README]]"]
depends_on: ["[[docs/requirements/eta-crux/core-loop]]", "[[docs/requirements/eta-crux/errors]]", "[[docs/requirements/eta-crux/dispatch]]"]
traces_to: []
---
# Subscriptions

## Intent

A subscription is a long-lived source of actions whose desired presence is
derived from application state. Eta Crux reconciles the desired subscription set
after graph stabilization, starting newly desired sources, preserving unchanged
sources, and stopping removed or changed sources.

A subscription is identified by a spec value and an application-supplied
equality or comparator. The mapper from stream item to action does not
participate in subscription identity.

Subscription sources are Eta streams. Stream items are mapped to actions and
admitted through the owner-domain action producer path. Stopping a subscription
interrupts the stream fiber and runs its release path.

## Requirements

- **sub-3k9t** (event-driven): When graph stabilization completes, eta_crux
  shall derive the desired subscription set from the stabilized application
  state.
- **sub-s4k9** (ubiquitous): When application code defines a subscription,
  eta_crux shall identify that subscription by its spec value and the
  application-supplied equality or comparator for that spec.
- **sub-b1w8** (state-driven): While a subscription's spec compares equal across
  reconciliations, eta_crux shall keep the subscription source running.
- **sub-9x4q** (event-driven): When a subscription's spec no longer compares
  equal across reconciliations, eta_crux shall stop the previous subscription
  source and start the replacement source.
- **sub-2h6n** (event-driven): When a subscription enters the desired set,
  eta_crux shall start its underlying Eta stream source.
- **sub-c3k8** (event-driven): When a subscription leaves the desired set or its
  owning scope is disposed, eta_crux shall interrupt the subscription stream
  fiber and run the source release path.
- **sub-m6r2** (ubiquitous): When application code maps subscription stream
  items to actions, eta_crux shall preserve the subscription identity defined by
  the spec value and shall not use mapper identity for reconciliation.
- **sub-v5c7** (ubiquitous): When a subscription mapper captures application
  values, eta_crux shall treat that capture as application code and shall not
  rely on mapper identity or mapper structure for subscription reconciliation.
- **sub-q2r8** (event-driven): When a subscription stream emits an item,
  eta_crux shall map the item to an action and enqueue the action through the
  owner-domain producer path.
- **sub-n8v5** (ubiquitous): When application code composes subscriptions,
  eta_crux shall provide an empty subscription and a batch combinator.
- **sub-e4t7** (event-driven): When a subscription source reports a typed error,
  eta_crux shall fold that error into an action; when a subscription source
  defects, eta_crux shall route the defect to the crash boundary.

## Open questions

- Exact public API for declaring subscription specs and their equality or
  comparator.
