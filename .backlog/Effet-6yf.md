---
id: Effet-6yf
title: "Survival lab: Resource module — does cached-loader earn its independent
  existence?"
status: open
priority: 2
issue_type: task
created_at: 2026-05-19T18:40:58.224Z
created_by: backlog
updated_at: 2026-05-19T18:46:56.559Z
dependencies:
  - issue_id: Effet-6yf
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:46:56.559Z
    created_by: backlog
---

# Survival lab: Resource module — does cached-loader earn its independent existence?

## description

Review 2 §2 challenges Resource's existence. The current Resource.t is a cached effectful loader with manual refresh and Resource.auto for scheduled refresh. The journal's own deferred reasoning is that auto-refresh 'should probably be expressed later as a subscription or a runtime-managed resource, not a pure-looking constructor', undercutting the module's identity.

Survival test: rewrite the entire Resource test suite using ordinary OCaml — Atomic.t cell + Effect.sync/Effect.bind for the loader, Effect.detach + Schedule for auto-refresh. If the replacement is not materially worse (clearer call-site? equivalent failure isolation? same auto-refresh fixtures pass?), Resource as a module is decorative.

Risk: deleting Resource removes a public surface and forces apps using it to roll their own. Mitigation: ship a recipe-doc replacement with the canonical loader pattern.

## design

Branch A: keep packages/effet/resource.ml as today.
Branch B: delete Resource module from effet's public surface. Rewrite the existing Resource tests using ordinary primitives:
- manual loader: Atomic.t (a option) + Effect.sync to read + Effect.bind for first-load fallback
- refresh: explicit Effect.t that retries the loader and updates the cell
- auto: Effect.detach + Schedule + same atomic cell

Compare:
- test LOC: Branch A test file vs Branch B
- ergonomics: how readable is the Branch B replacement?
- failure isolation: failed refresh keeps last-good — does that fall out naturally with primitives, or does Resource have important hidden behaviour?
- thread safety: does the Atomic.t version cover all cases the Resource module covered?

If Branch B is at-most marginally worse, Resource is unearned.

## acceptance criteria

scratch/resource_survival/ contains both branches. The existing Resource test suite passes on both with no behaviour change. journal.md gains a V-Rsv1..V-RsvN decision diary citing LOC and ergonomic comparison. Recommendation: (a) keep Resource with documented rationale; (b) delete Resource, replace with documentation showing the recipe — capture as migration task. 1.5h time budget.
