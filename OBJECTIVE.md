# Scoped Sessions Ergonomics — Lab

Worktree: `../Eta-scoped-sessions`, branch `research-scoped-sessions`.
Scratch lab: `scratch/eta_research/scoped_sessions/`.
This file is the single planning entry point for the experimenter agent.

This is a **small lab**. The question is constrained, the cost of being
wrong is bounded, and the boring baseline is a likely answer. Three
probes, same hard rules as the Ladybug / Graph-Query / Turso labs,
scoped down.

---

## Goal

Decide whether Eta should add a public ergonomics layer for the
"long-lived child fiber + handle escape into a callback" pattern, or
whether existing primitives (`Supervisor.scoped`, `Scope.start`,
`Scope.await`, `Effect.acquire_release`) plus documentation are
sufficient.

The motivating consumer: camelpie's PTT streaming session. The agent
working on it reached for `Effect.Private.daemon` because the existing
structured-concurrency primitives required reshaping camelpie's API
shape, and that reshape felt heavy. The question is whether the
reshape is *genuinely* heavy enough to justify a new helper, or
whether it's a one-time camelpie cost that doesn't generalize.

This is a **library-or-recipe survival lab** in the V-Pool / V-Channel
/ V-Rs / V-Latch shape. The decision criterion is the same: a helper
earns its place if it centralizes a real protocol; a helper that only
renames existing primitives is rejected.

---

## Accepted prior art (do not reopen)

- **Structured concurrency is non-negotiable.** Eta does not ship a
  public unsupervised-spawn primitive. `Effect.Private.daemon` stays
  Private. (Decided by Eta's identity and reaffirmed by V-Effect-Services.)
- **`Effect.acquire_release` is the resource pattern.** Already shipped.
- **`Supervisor.scoped` + `Scope.start` + `Scope.await`** is the
  existing scoped-child pattern. Already shipped.
- **`Pool.with_resource`** centralizes one specific case (bounded
  acquire/release with eviction) and is shipped.
- **H-W4 wrap policy applies.** A helper earns its place when it
  preserves an Eta-owned invariant — typed failure preservation,
  cancellation cleanup, scoped lifecycle, close fences, backpressure
  ownership, mode/portability fences, observability. Otherwise the
  consumer should use the existing primitives directly.

---

## Hypothesis space

Four branches. All must be tested against the consumer survey. Do not
silently reject before P-Scoped-1 runs.

### Branch A — public `Supervisor.with_child` helper

```ocaml
val Supervisor.with_child :
  ('child_result, 'err) Effect.t ->
  (('child_result, 'err) child -> ('a, 'err) Effect.t) ->
  ('a, 'err) Effect.t
```

Strongest reading: the start-child / use-handle / cancel-or-await
sequence is genuinely a protocol that several consumers replicate
identically. The helper centralizes typed failure flow from child to
parent, cancellation on callback exit, observability seam.

Plausible falsifier: only camelpie hits this pattern. The "protocol"
is one-shot. The helper renames `Supervisor.scoped + Scope.start +
Scope.await` without centralizing anything.

### Branch B — public `Resource.with_session` (or similar name)

A session-specific resource pattern. Streaming WebSocket is
conceptually a resource: open → use → finish/cancel → close. A helper
that names that lifetime and ensures it composes with `Effect.timeout`
and parent `Switch` cancellation.

Strongest reading: stream sessions are common across camelpie,
OpenAI Realtime, eta-otel batching, and probably future agent-loop
consumers. They share more than just "fork-and-await" — they have
finish-vs-cancel asymmetry, drain semantics, and an observability
shape distinct from generic supervised children.

Plausible falsifier: this is just `Effect.acquire_release` with a
nicer name. If the consumer survey shows the existing primitive
already expresses every case cleanly, B is dominated by C.

### Branch C — recipe in docs, no new public API

Write the canonical recipe using existing primitives. Land one or two
worked examples. No API change.

Strongest reading: every consumer surveyed can be expressed with
`Supervisor.scoped + Scope.start + Scope.await + Effect.acquire_release`
in roughly the same LOC as a helper would produce, with no protocol
that a helper would centralize. The friction is *discoverability*, not
*expressivity*.

This is the boring baseline. It always wins when nothing earns its
place above it. Do not eliminate it.

### Branch D — refactor camelpie alone, no Eta change

Strongest reading: the friction is camelpie-shaped. PTT streaming has
an unusual `start_stream_session : ... -> handle` API that returns a
free handle from a function, which is the actual problem. Other
consumers don't replicate this; their session APIs are already
callback-shaped. Fix camelpie, leave Eta untouched.

Plausible falsifier: when the consumer survey runs, three or more
candidates have the same `start → handle → use → finish/cancel`
shape camelpie has. Then it's a pattern, not a camelpie quirk.

---

## Probe order — hardest first, stop on falsifier

### P-Scoped-1 (HARD, decides the lab): consumer survey

This single probe usually closes the lab. If only camelpie hits the
friction, Branch D wins and the lab ends. If three or more genuinely
independent consumers hit the same boilerplate, A or B earn their
place.

Survey 3–5 candidate consumers of the "long-lived child + handle
escape" pattern that exist or are imminent. Suggested set:

- **camelpie PTT streaming** — concrete, motivating consumer.
- **OpenAI Realtime session** (`Eta-n0v4` in backlog) — almost
  certainly the same shape.
- **HTTP/2 multiplexer writer-fiber pattern** — already shipped in
  `lib/http/h2/multiplexer.ml`. Does it benefit retroactively from
  any of the proposed helpers, or is it different?
- **eta-otel batching loop** — long-running background batcher with
  finish/cancel semantics. Same shape?
- **Hypothetical agent-loop / chat-session consumer** — the future
  shape eta-ai might need.

For each consumer, **write the consumer code under all four branches**.
Compare:

- LOC at the call site
- LOC of the helper implementation (if any) for branches A and B
- error-path correctness (typed failure flow)
- cancellation correctness (parent-cancels-child, child-fails-cancels-parent)
- observability seam (does each branch surface the child fiber to
  Tracer / Capabilities cleanly?)
- discoverability (would a new contributor write this correctly
  without reading docs?)

A branch is **dominated** if Branch C is at least as clean for ≥80%
of consumers. A branch is **eliminated** if it cannot express one of
the consumers without a documented escape hatch.

Capture: `scratch/eta_research/scoped_sessions/p_scoped_1/coverage_matrix.md`
with a 4-branch × N-consumer grid, plus runnable fixtures
demonstrating at least Branch C and Branch A or B for the camelpie
consumer.

Verdict shapes:
- **Branch D wins** — only camelpie hits it. Refactor camelpie, write
  one passing-mention recipe in `lib/eta/`'s docs, close the lab.
- **Branch C wins** — multiple consumers, but existing primitives
  express each cleanly. Ship recipe + worked examples in docs. No
  new API.
- **A or B wins** — multiple consumers, helper genuinely centralizes
  a protocol that consumers would otherwise replicate. Proceed to
  P-Scoped-2.

### P-Scoped-2: protocol centralization test (only if A or B survives)

For the surviving branch, prove the helper centralizes a real protocol.
At least one of:

- typed failure preservation across the parent/child boundary that
  consumers would otherwise have to wire by hand;
- cancellation cleanup that's hard to get right without the helper;
- close fences (parent must drain child output before close);
- observability seam (child fiber automatically registered with the
  parent's Tracer);
- mode/portability fence (helper enforces that `'err` and the child's
  result flow correctly across the boundary).

If none of these survive scrutiny — if the helper is "a slightly
shorter way to write `Supervisor.scoped + Scope.start + Scope.await`"
— it doesn't centralize a protocol. Branch C wins; lab closes with
the helper rejected.

Capture: `scratch/eta_research/scoped_sessions/p_scoped_2/protocol.md`
documenting which invariant the helper preserves and what consumer
boilerplate disappears as a result.

### P-Scoped-3: camelpie refactor under the winning branch

Whichever branch wins, perform the camelpie refactor. Capture the diff
from the current `Effect.Private.daemon` shape to the new shape under
the chosen branch. Note:

- LOC delta in camelpie
- Whether `Effect.Private.daemon` use is fully removed or only reduced
- Any remaining friction the consumer survey didn't anticipate

This probe is a sanity check: if the supposed winner produces a
camelpie diff that's *not* materially clearer than the current code,
the verdict has no empirical support.

Capture: `scratch/eta_research/scoped_sessions/p_scoped_3/refactor.diff`
plus `notes.md` summarizing the result.

This probe does **not** change camelpie itself — the diff is captured
under the lab as evidence; the actual camelpie change happens on a
separate branch after the lab closes.

---

## Hard rules

Inherited from the prior labs. They worked. Same rules, no edits.

1. **No verdict without a captured run-log artifact.** Notes that say
   "tested" without a corresponding fixture or diff are filed as
   **Untested**, not as a verdict.
2. **No paper analysis dressed as evidence.** If the probe needs
   actual code to surface the issue (consumer A's call-site
   compared to consumer B's), write the actual code. Do not
   compare prose descriptions.
3. **No clean tables.** A 4×5 coverage matrix where one branch is
   uniformly clean is suspect. Mixed verdicts are expected.
4. **Surprise findings are the deliverable.** Findings that contradict
   the user's expected verdict are evidence, not failure.
5. **Self-correction is reportable.** If a later probe contradicts an
   earlier verdict, lead with the contradiction.
6. **Steelman before falsifying.** Each branch gets a real attempt.
   Branch C ("recipe in docs") must be tried with a *well-written*
   recipe, not a deliberately weak one. Same for Branch A's helper
   API and Branch B's session shape.
7. **Truth is not proof cost.** If finding three additional consumers
   takes time, that's the cost of the research, not evidence against
   them existing.
8. **The user has not pre-decided.** "Branch D probably wins" is the
   user's prior, not an answer to confirm. The lab tests against
   evidence.

---

## Stop conditions

- **P-Scoped-1 falsifies all four branches** (no consumer can be
  expressed cleanly under any branch). Pause and report; this is a
  bigger architectural finding than the lab anticipated.
- **P-Scoped-1 finds only camelpie.** Branch D wins. Lab closes. No
  P-Scoped-2 or P-Scoped-3 needed. Report and close.
- **P-Scoped-2 falsifies the surviving helper branch** (no real
  protocol). Branch C wins; ship docs + examples. Lab closes.

The lab does **not** pause on:
- Mixed verdicts within Branch A or B (one consumer benefits, another
  doesn't). That's a finding; document the fit-set.
- Multiple branches surviving. That's also a finding; pick one based
  on the protocol-centralization test in P-Scoped-2.

---

## Acceptance criteria

The lab closes when:

1. P-Scoped-1's coverage matrix exists at
   `scratch/eta_research/scoped_sessions/p_scoped_1/coverage_matrix.md`
   with all consumer × branch cells classified, and at least Branch C
   plus the strongest helper candidate fixtured against the camelpie
   consumer.
2. If a helper survives: P-Scoped-2 produces
   `scratch/eta_research/scoped_sessions/p_scoped_2/protocol.md`
   documenting the protocol, OR records "no protocol centralized"
   as the verdict.
3. P-Scoped-3 captures the camelpie refactor diff under the winning
   branch.
4. `scratch/eta_research/scoped_sessions/results.md` summarizes
   verdicts, surprise findings, and what was not measured.
5. `scratch/eta_research/scoped_sessions/adr.md` proposes either:
   - the public API addition (Branch A or B) with rationale; or
   - the recipe-in-docs path (Branch C) with the recipe text drafted; or
   - the camelpie-refactor-only path (Branch D) with no Eta change.
6. Journal entry `V-Scoped-Sessions` at the bottom of `journal.md`
   recording the verdict and what was not measured.

The lab does **not** require:
- Implementation of the chosen API. (Lab outputs the ADR; if a helper
  is approved, implementation is a separate task.)
- Production benchmarks of helper vs raw primitive.
- Full camelpie refactor. (P-Scoped-3 captures the diff as evidence;
  the actual camelpie patch lands later.)
- Surveying every possible consumer in the codebase. (Three to five
  is enough; more if naturally surfaced.)

---

## Non-goals

- Reopening structured concurrency. Eta does not ship public
  unsupervised-spawn. That's settled.
- Reopening `Effect.Private.daemon`'s privacy. It stays Private.
- Adding observability primitives. (Tracer integration is in scope
  *as a question* — does the helper need one? — but a new Tracer API
  is out of scope.)
- Designing a fiber-handle / FiberRef / FiberHandle abstraction. (See
  separate backlog tasks. This lab is narrower: just the start-use-
  cancel scoped pattern.)
- Refactoring `Pool` or `Resource` or any existing module to fit a
  new shape.
- Writing the implementation in `lib/eta/`. The lab outputs an ADR; a
  helper, if approved, lands on a separate branch.

---

## Deliverables (per probe)

- `notes.md` — what was tested, what was measured, verdict, what was
  **not** measured.
- Fixture files (`.ml`, `.dune`) for runnable comparisons.
- Captured logs or diffs as artifacts.
- For P-Scoped-1: `coverage_matrix.md` is the central deliverable.

---

## What good looks like

- A 4-branch × N-consumer coverage matrix with mixed cells.
- An honest answer: either "only camelpie" (D wins), or "multiple
  consumers, existing primitives suffice" (C wins), or "multiple
  consumers, helper centralizes [protocol]" (A or B wins).
- At least one surprise — a consumer the lab didn't expect to fit
  the pattern, or a consumer that does fit but for a different reason
  than camelpie does.
- An ADR that an implementer can read in under 15 minutes and act on
  the same day.

## What bad looks like

- A coverage matrix where Branch A or B is uniformly clean and the
  others uniformly fail. (Probably the agent steelmanned only one
  branch.)
- A verdict that "the user wants Branch C" wins with no evidence
  weighed against it.
- A verdict that adds a public API based on one consumer.
- An ADR that proposes a helper without naming the protocol it
  centralizes.

If any of these appear, the lab is not closing — it is restarting.
