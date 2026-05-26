# effect_services lab

Scratch lab backing the worktree `../Eta-effect-services`.

The full plan, hypothesis space, falsifiers, and acceptance criteria live in
the worktree's `OBJECTIVE.md`. This README is a navigational index.

## Layout

    p0_prior_art/        — survey of Effekt, Eff, Koka, Eio FLS, multicore OCaml
    p1_locality/         — HARD FALSIFIER: handler propagation across Fiber.both,
                           Fiber.fork, Switch.run, Effect.timeout, Supervisor.scoped,
                           acquire_release. Stop-condition probe.
    p2_composition/      — multi-library service-effect declaration ergonomics
    p3_cancellation/     — perform during cleanup / finalizer / cancelled fiber
    p4_unhandled/        — runtime failure mode for missing handlers + mitigations
    p5_dx/               — DX comparison: argument-passing vs effect-handler on the
                           same real-shape consumer (HTTP-style retry+log+trace)
    p6_mocking/          — mocking ergonomics on the same fixture
    p7_boundary/         — observable rule classifying services as effect or value
    p8_di/               — opt-in DI sketch (runs only if P1–P7 favorable)

    adr.md               — single ADR recording the final verdict
    results.md           — top-level summary across all probes

## Run order

P0 → P1. If P1 fails, stop. Otherwise P2..P6 in any order, then P7 distills
the rule, P8 sketches the DI utility iff the rule is non-empty.

## What the lab will not do

- Edit anything under `packages/`.
- Reopen V-R5 (drop `'env` channel) or V-Native-Effects (replace runtime AST).
  Both decisions stand. This lab studies effects as an *additive* service
  mechanism, not a replacement for any existing one.
- Produce performance numbers. Microbench of native effect handlers is covered
  by `../Eta-native-effects/scratch/eta_research/native_effects_pivot/`.

## Build

    nix develop -c dune build scratch/eta_research/effect_services

Each probe directory will get its own `dune` stanza when the probe author lands
the first runnable fixture. Negative fixtures (compile-must-fail probes) are
excluded from `dune` and added one at a time per the project convention.
