# Follow-up 2: DX-E24b — correct the deletion proposal (document-level)

The re-audit upholds the revised verdict (D as deletion proposal is SOUND;
all six prior findings closed). Two MEDIUM errors in
`review/DELETION_PROPOSAL.md` and two smaller corrections must land before
this merges — the proposal is the document the implementation experiment
will execute from.

## 1. MEDIUM: the accepted loss is understated

The 0/5 loss is not just "branch/phase-local events within one composed
step". Deletion removes ALL schedule-local effect boundaries:

- top-level terminal `Done` output observation;
- access to policy-generated outputs (e.g. the delay series as values);
- schedule-local effects at the policy-evaluation/driver-publication
  boundary;
- the hook-failure / cancellation **advancement veto** (tap-failure tests
  in retry, stream, and resource demonstrate control flow, not merely
  telemetry);
- arbitrary custom-effect-system interpretation through `step_plan`.

Rewrite the loss description as "all schedule-local effect boundaries,
with branch/phase-local events as the strongest example", keep the honest
ratings, and state explicitly that each lost boundary has no demonstrated
production demand (that is why the trade holds).

## 2. MEDIUM: the E22 deletion slice is wrong

M106–M111 describe `Schedule.named`, which SURVIVES deletion (`pp` label,
stepping behavior, no-automatic-telemetry claims — LAWS.md:135–140).
Correct the slice to:

- delete M65–M67, M95–M105, M112;
- rewrite M106–M111 keeping the surviving `named` claims (only M108's
  hook-order portion disappears) — a small no-hook `named` property
  replaces the tap-based combined one;
- delete R96/R102;
- split/rewrite the tap-specific portions of R80/R100;
- preserve M68 (`next`), R94 (`Continue` delay), R95 (`jittered` random).

## 3. Demand gate widening

The reversal gate should cover ANY demonstrated schedule-local effect
requirement, not only observability — e.g. terminal-output handling or a
failure-based advancement veto with no ordinary recipe. Reword the third
bullet accordingly.

## 4. Ancillary completeness (LOW)

Add to the slice: the non-tap ternary test annotation at
`test/core_common/properties_common_suites.ml:12`; the disposition of the
old C and `no_hook` red-team fixtures (rework or remove so `run-all.sh`
stays meaningful post-deletion); and the durable status summary in
`docs/research/dx.md` (still records E24b as a pending permanent-retention
question — the implementer must update it when the deletion lands).

## Records and gates

Journal: append-only entry with the four corrections. Report +
DELETION_PROPOSAL.md updated. Gates: native trio; mainline `@install` +
`test/laws`; red-team script still green.

## Done means

`E24B READY FOR REVIEW` / `E24B BLOCKED: <reason>` / `E24B STOP: <§4.6>`.
Same scope fence. This file stays uncommitted.
