# Representative consumer friction

Date: 2026-08-10
Ticket: [`docs/wayfinder/eta-crux-capability-audit/issues/07-representative-consumer-friction.md`](../../../docs/wayfinder/eta-crux-capability-audit/issues/07-representative-consumer-friction.md)
Baseline: [`01-current-eta-crux-capability-baseline.md`](01-current-eta-crux-capability-baseline.md)

## Question

What repeated application or adapter work appears in representative Eta Crux
consumers?

## Sources inspected

| Source | Role | Commit |
|---|---|---|
| Eta worktree (this tree) | In-repo Crux consumers: bench, tests, research adapters | `d977a970ac133aa3224bd0ffb67ef7c632cd3672` |
| Baseline report | The nine reported gaps and their classification | `6ab2269e` in the main Eta repo |
| Taumel | Consumer of Eta core (not Crux) | `26505e55f731b5b9a7a9506649ebe75cc4b08f69` |
| Sliml | Consumer of Eta only in scratch evidence | `d03702bc3ee2dfce916c460ee7d4a7ff84ae7286` |

I inspected source files, repository documentation, tests, and git history.
I did not run the test suite.

## Evidence limits

1. **Taumel and Sliml do not use Eta Crux.** Taumel depends on `eta`,
   `eta_http`, `eta_js`, and `eta_jsoo` (`taumel.opam` lines 15-19), pinned to
   Eta commit `ff08a342`. Sliml's main library depends only on OCaml
   (`sliml.opam` lines 9-13) and uses Eta only in the scratch evidence lab
   `.scratch/evidence/host-surface-popper/`. Their friction is friction with
   the Eta substrate, not with Eta Crux. Mapping their patterns onto the nine
   Crux gaps is analogical evidence, not direct evidence.
2. **The only direct Eta Crux consumers are in-repo.** They are
   `lib/crux/bench/bench_eta_crux.ml`,
   `test/crux/**`,
   `.scratch/research/eta-crux-bonsai-bench/eta_adapter.ml`, and
   `.scratch/research/evidence/eta_incremental_performance/crux/compare.ml`.
3. **Single-consumer evidence is labeled.** Patterns found only in Taumel
   (notification claims, turn clock, action capability) or only in one test
   file are single-consumer evidence. They show that a pattern exists. They do not
   show the pattern is a requirement.
4. **This report does not design a remedy.** It records patterns, frequency,
   complexity, failure modes, and a classification. It does not decide what
   Eta Crux ownership.

## The nine reported gaps

The nine gaps are the open tickets `issues/09` through `17`. The baseline
classifies them as `missing`, `application-composable`, `partial`, or
`deliberately excluded` (baseline summary table, lines 353-367). This report
records what consumers actually build around each gap.

| Gap | In-repo Crux consumer evidence | Taumel evidence (Eta core) | Sliml evidence | Result |
|---|---|---|---|---|
| 1 Graph time and clock control | Tests control Eta fiber time with `Eta_test.with_test_clock` (45 uses in `test/crux/`, including 23 in `test_eta_crux_core.ml`). Tests advance it by hand (`Test_clock.adjust` at `test_eta_crux_core.ml:952,1072,1189,2036`, `test_eta_crux_conformance.ml:454`, `test_eta_crux_telemetry.ml:346`). The telemetry test advances the clock from inside a Crux projection (`test_eta_crux_telemetry.ml:346`). `eta_crux_test.mli` has no clock API. | Hand-built clock state machine with pause/resume (`lib/plan_accounting.ml:7-12,156-202`), driven by wall clock `now_ms` (`bin/app_state.ml:226-230`). Cron gets time as a host input (`bin/cron_tools.ml:449-453`). Waits race `Effect.sleep` against promises (`bin/exec_session.ml:423-431`, `bin/agent_wait_runtime.ml:45-65`). | None | Consumers build time control by hand. Evidence is strong that the pattern exists. It is multi-consumer only for the host-time input style. |
| 2 External graph input | All in-repo consumers change state only through `Endpoint.send` or `Exported_endpoint.try_invoke` (`bench_eta_crux.ml:24-29,408`, `eta_adapter.ml:92-118`, and every unit test). No other input path exists in `eta_crux.mli`. | Host state changes arrive as decoded facts per `core.call` method (`bin/taumel_main.ml:25-315`) and mutate global state. | None | No consumer exhibits a different input shape. No counter-evidence. |
| 3 Startup facts and flags | Root construction closes ordinary values (`Root.create` at `eta_crux.mli:577-581`, bench `bench_eta_crux.ml:69-79,330-333`, and `eta_adapter.ml:145-147`). | Startup loads persisted state through ordinary load helpers (`bin/session_sync.ml:301-317` plan automation load, `initialize` in `bin/taumel_main.ml:319-332`). No flags concept. | None | No consumer shows a distinct startup-flags pattern. Evidence is absent for a need. |
| 4 Staged-effect observability | Tests assert staging with side-effect counters (`test_transition_effect_is_staged`, `test_eta_crux_core.ml:102-120`), event lists (`test_adapter_commit_boundary`, `test_eta_crux_test_surface.ml:265-321`), injected controlled dependencies (`Eta_test.Controlled` in `test_eta_crux_laws.ml:3152-3224`), and a controlled source (`test_eta_crux_laws.ml:3226-3299`). `Controlled_source` has one in-repo consumer (the laws test). | Tests assert interruption and cancellation with counters and timeout races (`test/test_eta_host_doors.ml:96-130,154-185`). | None | Effect assertions are the repeated pattern. Multi-consumer within the Crux test suite. |
| 5 Host-owned streaming operations | `Source` emits many items into actions (`qcheck_source_*` laws and `test_eta_crux_core.ml:623-730`). Host operations resolve once (`qcheck_request_first_resolution` and bench resolve `bench_eta_crux.ml:461-479`). | Exec sessions are a hand-built many-response host operation: mutable lifecycle record (`bin/exec_session.ml:18-34`), output accumulation (`bin/exec_output.ml:3-15,138-165`), one-shot terminal consumption (`bin/exec_session.ml:447-459`), completion promise, notification state machine (`bin/exec_session.ml:819-877`), per-owner session cap (`bin/exec_session.ml:44,542-551`). | None | The many-response host-operation pattern exists in one consumer (Taumel) with substantial complexity. |
| 6 Ingress admission classes | Root-wide FIFO and capacities only. Bench verifies exact capacity with `try_invoke` returning `Full` (`bench_eta_crux.ml:404-425`). No class API exists in `eta_crux.mli`. | Application-level admission limits by hand: exec session cap per owner (`bin/exec_session.ml:44,542-551`), cron delivery coalescing (`bin/cron_tools.ml:500-507`), notification claim protocol (claim, release, and mark delivered at `bin/exec_session.ml:819-877` and `bin/agent_lifecycle.ml:361-451`). | None | Per-owner limits and coalescing exist in one consumer (Taumel). Root-wide FIFO is the only Crux-provided behavior. |
| 7 Pull observation of root output | Test package provides pull: `Handle.last_output` (`eta_crux_test.mli:71`), backed by a `mutable output` shadow field set only after successful delivery (`crux_test_handle.ml:67-75,89-90,141-142,320-324`). Production driver keeps a private `last_output` set on commit (`crux_driver.ml:204,515`, with its field at `crux_driver_base.ml:59`). No in-repo test calls `last_output`. | Application caches pushed output for on-demand reads: exec session output (`bin/exec_session.ml:946-951` process manager output), agent run final/partial output read on demand (`bin/agent_lifecycle.ml:992-1006`). | None | The pull cache pattern appears in both the test package and Taumel. In-repo `last_output` has no in-repo caller. |
| 8 Host-operation layers | Tests and bench hand-write dispatch chains over `Driver_event.handle` plus `accepted` (`bench_eta_crux.ml:461-479` and `test_eta_crux_core.ml:210-224`). No middleware module exists (`eta_crux.mli`). | `core_call` is a hand-built dispatch table of about 150 string-named methods (`bin/taumel_main.ml:25-315`). Every handler decodes facts, checks ownership, and commits state. A manual capability-claim layer wraps the same actions (`bin/agent_action_capability.ml:36-38,57-63,173-226`). | None | Hand-written dispatch and layering is the repeated pattern. Only the Crux bench/tests use the actual `handle` chain. |
| 9 Action history and diagnostics | No action log in `eta_crux_test.mli`. Crash diagnostics are `Failure.record` snapshots asserted in tests (`test_eta_crux_core.ml:898-902,1000-1007`). Telemetry is fixed logs/metrics/spans (`test_eta_crux_telemetry.ml`). | The app keeps its own durable history: session store entries (`bin/session_sync.ml:724-725,822-824`), cleanup journal records (`bin/agent_lifecycle.ml:724-731`), run records with completion status (`bin/agent_lifecycle.ml:206-256`). Diagnostic strings are built by hand: `string_cause_message` (`bin/exec_session.ml:433-437`), `cause_message` (`bin/eta_host_doors.ml:61-65`), `Printexc.to_string` at many call sites (`bin/agent_lifecycle.ml:31,749,762,768,776`), `report_session_sync_error` (`bin/session_sync.ml:24-30`). | None | Durable action history and cause-to-string diagnostics exist in one consumer (Taumel). The Crux test package exposes no history API. |

The table records observations. The classification column of the baseline
(lines 353-367) remains the source of truth for what Eta Crux currently owns.

## Additional repeated patterns

### P1 Repeated protocols

| Pattern | Locations | Frequency | Complexity | Failure mode when wrong | App-specific or framework-generic |
|---|---|---|---|---|---|
| Decode-facts-then-dispatch per host call | `bin/taumel_main.ml:25-315`, with `decode_ojs_contract` in 28 files under `bin/` | About 150 dispatch arms. One decode helper per contract. | Medium. Each arm repeats decode, ownership check, and state commit. | A decode mistake throws `invalid_arg` at the host boundary. A state-commit mistake leaves partial state. | Application-specific protocol, repeated per tool |
| Claim / deliver / mark / release notification protocol | Exec notifications `bin/exec_session.ml:819-877` and agent notifications `bin/agent_lifecycle.ml:361-451` | Two instances in one consumer | Medium. Four states with explicit claims. | Double delivery or lost notification. Extra claim lists guard against both failures. | Application-specific. The shape repeats twice in one consumer. |
| Manual rollback of a multi-step update | `bin/agent_lifecycle.ml:58-80` (rollback_unaccepted_start), `82-132` (rollback_send_preflight), `159-179` (rollback_failed_interruption), `589-769` (finish_ephemeral_cleanup) | Four instances in one consumer | High. The cleanup transaction spans stage, tombstone, journal, and finalize. | Partial commit leaves orphans or stranded leases. The code has explicit unstage and restore branches. | Application-specific |

### P2 Duplicated state

| Pattern | Locations | Failure mode when wrong |
|---|---|---|
| `agent_notification_claims` list mirrors run state | `bin/agent_lifecycle.ml:368-374,417-418,427-428,438` | Claim list and registry disagree. A notification is skipped or sent twice. |
| `retained_sessions` table duplicates terminal info of removed sessions | `bin/exec_session.ml:36-42,87,391-419,907-915` | Retained snapshot and live session diverge. The system shows a stale exit code. |
| Exec session mutable claim fields | `bin/exec_session.ml:27-33` (`notification_state`, `notification_delivery_claimed`, `active_write_stdin_claims`) | Concurrency mistakes cause double consume or lost notification |
| Test handle `mutable output` mirrors driver `last_output` | `crux_test_handle.ml:67-75,89-90` vs `crux_driver.ml:204,515` | The two pull points diverge (committed vs delivered), as the baseline notes (baseline lines 246, 281-287) |
| `cron_state` table separate from session store | `bin/cron_tools.ml:452-454,509` | Crash between tick and save loses a delivery |
| Epoch table for staleness | `bin/agent_state_epochs.ml:1-16` | Stale call accepted after replacement |

### P3 Adapter caches

- Exec output buffer with truncation and temp spill (`bin/exec_output.ml:3-15,31-54,117-165`).
- Session and retained tables (`bin/exec_session.ml:85-87`).
- Agent run final/partial output stored in state, read on demand (`bin/agent_lifecycle.ml:992-1006`).
- Test handle `last_output` cache (`crux_test_handle.ml:89-90`).
- Driver private `last_output` cache (`crux_driver.ml:515`).

All of these cache pushed output so a caller can read the latest value later.
The test package ships one such cache. Taumel builds several. The failure mode
is staleness or divergence between the cache and the authoritative state.

### P4 Shadow queues

- Parked waiters table with one-shot wake promises (`bin/agent_wait_runtime.ml:14-24,45-65`).
- Pending agent-action reservations (`bin/agent_action_capability.ml:36-38,57-63`).
- Notification claim lists (`bin/agent_lifecycle.ml:368-374`).
- Benchmark uses an `Eta.Queue` to gate lifecycle cleanup releases (`bench_eta_crux.ml:223-247,259-263`).

The failure mode is a shadow entry that is never removed, which leaks a parked
waiter or keeps a capability alive past its TTL. Taumel sweeps expired
capabilities by hand (`bin/agent_action_capability.ml:57-63`).

### P5 Time control

- `Eta_test.with_test_clock` and `Test_clock.adjust` in Crux tests (45 uses in `test/crux/`, with adjust sites in the gap table).
- Hand-built turn clock with pause depth and accumulated pause (`lib/plan_accounting.ml:7-12,156-202`).
- Host-supplied `now` for cron ticks (`bin/cron_tools.ml:449-453`).
- Wall-clock reads `now_ms` / `now_seconds` (`bin/app_state.ml:226-230`).
- `Effect.sleep` raced against promises for deadlines (`bin/exec_session.ml:423-431,475-486` and `bin/agent_wait_runtime.ml:45-65`).

The failure mode for a wrong hand-built clock is wrong elapsed time, as in the
pause accounting logic (`lib/plan_accounting.ml:167-202`), which must add or
subtract pause time exactly. The telemetry test shows a test advancing the Eta
clock from inside a Crux projection (`test_eta_crux_telemetry.ml:346`), which
is Eta-runtime time, not Crux graph time.

### P6 Host-resource lifecycle

- Exec session lifecycle by hand: spawn, kill, close temp, retain, prune, cap (`bin/exec_session.ml:461-486,393-419,795-811`).
- Cleanup transaction with lease, stage, tombstone, journal, rollback (`bin/agent_lifecycle.ml:589-769`).
- Bracketed resource release with `Eta.Effect.acquire_release` (`sliml/.scratch/evidence/host-surface-popper/c5.ml:48-68`).
- Crux lifecycle gating in tests: `test_lifecycle_resource_cleanup` (`test_eta_crux_core.ml:400-435`), `test_structural_scope_settlement` (`437-541`), bench `lifecycle.overlapping_cleanup` (`bench_eta_crux.ml:222-263`).

The failure mode is a resource that is not released or is released twice.
Consumers handle this with `Effect.finally` and `acquire_release` (Taumel
`bin/exec_session.ml:791-793` and Sliml `c5.ml:48-68`) or with manual rollback
branches (Taumel `bin/agent_lifecycle.ml:705-769`).

### P7 Effect assertions

- Counter refs around staged effects (`test_eta_crux_core.ml:102-120`).
- Event-list assertions for ordering (`test_eta_crux_test_surface.ml:265-321`).
- `Eta_test.Controlled` for FIFO and one-shot dependency checks (`test_eta_crux_laws.ml:3152-3224`).
- `Controlled_source` for source incarnation control (`test_eta_crux_laws.ml:3226-3299`).
- Forked waiter with `timeout_as` plus manual clock advance (`test_eta_crux_core.ml:1054-1073,2036`).
- Interruption and cancellation counters (Taumel `test/test_eta_host_doors.ml:96-130,154-185`).

The failure mode is a false pass when the assertion observes a downstream
consequence instead of the staged effect. The tests address this by gating
observation with promises (`test_eta_crux_core.ml:736-747`) and by checking
counters before post-commit starts (`test_eta_crux_core.ml:118-120`).

### P8 Diagnostic work

- Cause-to-string conversion: `string_cause_message` (`bin/exec_session.ml:433-437`), `cause_message` (`bin/eta_host_doors.ml:61-65`), `Eta.Cause.pp` at several call sites.
- Exception stringification with `Printexc.to_string` (`bin/agent_lifecycle.ml:31,749,762,768,776`).
- Error report helper with stale-context filtering (`bin/session_sync.ml:18-30`).
- Human-readable manager snapshots (`bin/agent_lifecycle.ml:473-587,878-900`).
- Crux crash snapshots asserted in tests (`test_eta_crux_core.ml:898-902,1000-1007`).
- Sliml has its own diagnostic type in the main library (`lib/sliml_diagnostic.ml:13-45`), which does not use Eta.

The failure mode is a lost or misleading diagnostic when code unpacks a cause
incorrectly. `string_cause_message` takes only the first cause in a list
(`bin/exec_session.ml:434-436`).

## Classification summary

| Pattern | Evidence strength | Classification |
|---|---|---|
| Time control and clocks | Multi-consumer (Crux tests, Taumel, and host-time input style) | Framework-generic shape. Every instance is hand-built. |
| External graph input | No counter-evidence. All consumers use actions. | Application-composable today |
| Startup facts | Evidence absent for a distinct need | Application-composable today |
| Effect assertions | Multi-consumer within Crux test suite | Framework-generic for tests. `Eta_test.Controlled` and `Controlled_source` already exist in the test package. |
| Many-response host operations | One consumer (Taumel exec sessions) | Application-specific. Single-consumer evidence. |
| Admission limits and coalescing | One consumer (Taumel) | Application-specific. Single-consumer evidence. |
| Pull observation caches | Two sources (Crux test handle and Taumel output caches) | Framework-generic shape. Implemented per site. |
| Host-operation dispatch layers | Two shapes (Crux `handle` chains and Taumel `core_call`) | Framework-generic shape. Each consumer hand-writes it. |
| Action history and diagnostics | One consumer (Taumel durable history) | Application-specific. Single-consumer evidence. |
| Claim / rollback protocols, shadow queues, duplicated state | One consumer (Taumel) | Application-specific. Single-consumer evidence. |

## Conclusions

These conclusions follow from the observations above. They do not decide
adoption or rejection of any capability.

1. **Eta Crux has no external consumer beyond this repository.** Taumel and
   Sliml use the Eta substrate, not Eta Crux. Their patterns are indirect
   evidence for the Crux gaps.
2. **The most repeated consumer work is time control.** Every consumer that
   needs time builds its own clock, deadline race, or host-now input. This
   matches gap 1 and the baseline classification `missing`.
3. **Pull observation is the only gap with a framework-provided partial
   answer, and that answer is test-only.** The test package ships `last_output`.
   no in-repo test calls it. Production pull does not exist. This matches gap 7.
4. **The many-response host operation, admission limits, claim protocols,
   durable history, and manual rollback appear in exactly one consumer
   (Taumel).** Per the ticket rule, no requirement is inferred from these.
5. **Effect assertions are already served by the test package** through
   `Eta_test.Controlled` and `Controlled_source`, plus opaque effects and
   post-commit fences. This matches gap 4's `partial` classification.
6. **Diagnostic work in consumers is cause-to-string and exception
   stringification.** Crux provides `Failure.record` snapshots and fixed
   telemetry. Consumers still convert causes to text by hand.

## Uncertainty

1. Line numbers were read at the recorded commits. I did not run the test
   suite, so pass or fail status of any gate was not re-executed.
2. Taumel's `bin/` directory is large (1052 lines in `agent_lifecycle.ml`,
   966 in `exec_session.ml`). I read the Eta-using and lifecycle files fully.
   I did not read every file in the repository.
3. `Eta_crux_test.Recording_adapter` is defined in the test package
   (`eta_crux_test.mli:191-231`) but has no in-repo consumer. Its usefulness to
   external consumers is unknown.
4. The claim lists, epoch tables, and waiter tables in Taumel are runtime
   state. They are not persisted. Their exact lifetime across session
   replacement was not traced.
5. `docs/design/eta-crux-v1/README.md` lines 86-94 list the deliberate V1
   exclusions. That list is design authority, not consumer evidence. This
   report did not re-derive it.
