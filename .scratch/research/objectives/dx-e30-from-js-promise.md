# Objective: DX-E30 — `Eta_js.from_js_promise`

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e30`
- Branch: `research/dx-e30-from-js-promise` (already checked out here; do not create others)
- Phase: queued candidate (post-Phase-D) · Effort S · Risk low–med (interop semantics)
- Evidence IDs: `V-DX-E30-*` (orchestrator log); your journal is the branch record
- Status: **human pre-approved** — the experiment is about doing it *sensibly*, not whether

## Executor profile

Small surface, precision work: one public adapter val in the `eta_js`
facade plus tests and docs. The difficulty is js_of_ocaml interop literacy
(`Js.Promise` bindings, `Js.Unsafe`, JS rejection semantics), fidelity to
E13's `Effect.async` contract, and Eta's typed-failure culture. Not a
migration job, not a design expedition: settle the three design questions
below with evidence, then implement the smallest honest answer.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. The jsoo
track lives on callbacks; wrapping a host JS `Promise` is its most common
interop shape, and it deserves one word, not a hand-rolled `Effect.async`
at every site. This is E13's first public consumption.

## Read first (in order)

1. `AGENTS.md` — Nix-only gates, no shims, delete old paths, break loudly,
   conventional commits.
2. `lib/eta/effect.mli` — the `Effect.async` contract (~lines 110–126):
   one-shot resolution, canceler rules, register-raises→`Die`, no lost
   wakeup. Your adapter inherits ALL of it; do not re-specify, do not
   weaken.
3. `docs/adrs/0001-http-js-fetch-and-transport-boundaries.md` — the
   capability discipline: missing host capability is a **loud typed
   failure**; Eta installs no polyfills.
4. `lib/js/eta_js.mli` + `lib/jsoo/eta_jsoo.mli` — facade conventions and
   the runtime host.
5. `.scratch/research/dx/e13/report.md` — how `Effect.async` was built and
   verified (substrate context; skim, don't cargo-cult).
6. `test/js_jsoo/test_eta_jsoo.ml` — how jsoo tests are written and run.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
The design questions below are open; answer them with small runnable
probes where the answer isn't forced by the contract, and record the
evidence in your journal. Working artifacts in `.scratch/research/dx/e30/`
**on this branch** (commit them): `journal.md`, `report.md`, `redteam/`
(as needed).

## The experiment (one-pager, from the DX ledger)

**Problem.** Wrapping a host JS `Promise` into `('a,'err) Effect.t`
currently means hand-writing `Effect.async` registration at every call
site. That's the E13 escape hatch doing application-level work — exactly
what E13 was built to prevent.

**Proposal.** One adapter in the `eta_js` facade:

```ocaml
val from_js_promise : (* shape to be finalized by you — see design questions *)
  ...
```

**Design questions (settle each with evidence; my sealed predictions
exist — do not read `.scratch/research/dx-journal.md`):**

1. *Signature/rejection mapping.* The typed-failure culture says the caller
   names the error mapping (an `~on_reject`-style argument). What is the
   exact rejection value type js_of_ocaml gives you, and what is the
   honest mapper shape? Is a convenience variant justified by usage
   evidence (there is none in-repo — check), or is the general form alone
   right? What do you name the mapper?
2. *Cancellation.* JS promises are not cancellable. Interruption must
   detach the waiter (later resolution dropped silently, no crash, no
   double-resume) — document that the host computation keeps running. Is
   an abort-style hook (e.g. `?on_cancel:(unit -> unit)`) justified for
   v1, or YAGNI until a consumer (http_js fetch lane) needs it? Decide by
   whether a real in-repo consumer exists today.
3. *Loud capability check.* What happens for a non-thenable at register
   time — typed host-policy failure (ADR 0001 style) or defect? Justify
   from who can produce the bad value (type system vs. host).

**Semantics & edges (the contract).**

- Inherits `Effect.async` wholesale: first resolution wins; register
  raising → `Cause.Die`; synchronous resolution during registration must
  not deadlock; no lost wakeup between registration and parking.
- Interruption detaches; resolution-after-detach is dropped silently.
- `Promise.reject(42)` (non-`Error` rejection) reaches the rejection
  mapper unchanged.
- Handlers attach synchronously during `register` (it is
  cancellation-protected until return) — no unhandled-rejection window,
  no lost wakeup for already-settled promises. Probe both.

**Gates (pre-registered).** *Promote* when the contract above is
implemented, tested, and documented within the doc budget (≤ ~12 mli
lines). *BLOCKED* if `Effect.async`'s contract itself turns out to need
changes, or if js_of_ocaml's Promise bindings force a shape that violates
Eta's typed-failure culture (record the conflict raw and stop).

## Protocol (in order)

1. **Seal your predictions** in `.scratch/research/dx/e30/journal.md`:
   your answers to the three design questions, expected census/footgun
   deltas, and the risk you most expect to bite. Commit before any code
   change (`docs(dx-e30): seal predictions`). Never edit afterward.
   (Dual-sealing design: the orchestrator sealed its own set on master
   before this branch was cut; the branch inherits that commit. Yours is
   the second, independent set — that independence is the point, which is
   why reading the orchestrator's journal file is fenced below.)
2. **Docs-first.** Write the `.mli` contract for `from_js_promise` (≤ ~12
   lines, including the detach semantics and the rejection-mapping rule)
   before implementing.
3. **Implement the smallest honest answer.** No http_js migration, no
   AbortController wiring unless design question 2's evidence demands it.
4. **Gates** (exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build --build-dir=_build-mainline @install
   nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force
   ```
   (Native must stay green by construction — you touch no native code.
   The separate `--build-dir=_build-mainline` prevents track poisoning.)
   Fix-forward up to three attempts per failure class, then BLOCKED.
5. **Mechanical extras.**
   - Tests in `test/js_jsoo`: resolve; reject → typed failure via the
     mapper; non-`Error` rejection fidelity; interrupt while pending →
     later resolution dropped, no crash, no double-resume; already-settled
     promise resolves without lost wakeup; non-thenable → loud failure
     (whichever shape question 3 decided).
   - Census: eta_js facade +1 val; note the new "interop" cluster's
     founding member. Footgun delta: expect +0.
   - `docs/api-dx.md` or the facade's own doc section: one short recipe
     ("wrapping a host promise") — one obvious way.
6. **Red-team pass**, committed under `.scratch/research/dx/e30/redteam/`
   with verdicts: (a) a forged non-thenable → loud failure, never a hang;
   (b) interrupt-during-pending, then force the promise to resolve →
   dropped silently; (c) `Promise.reject(42)` fidelity.
7. **Report** in `.scratch/research/dx/e30/report.md`: gates summary,
   design-question answers with evidence, census/footgun actuals vs. your
   sealed predictions (scored explicitly), red-team outcome, deviations,
   and your promote/hold/kill recommendation against the pre-registered
   gates.

## Done means

Your final message ends with exactly one of:

- `E30 READY FOR REVIEW`
- `E30 BLOCKED: <reason>`
- `E30 STOP: <§4.6 stop condition>`

The orchestrator then runs a PR-style adversarial review of the branch
diff (fresh oracle), judges taste, and decides. Rework via follow-up
messages.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md` (orchestrator's
  sealed predictions — reading them contaminates yours), `docs/research/`,
  `.scratch/research/dx-prd-0001.md`, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E30's surface: the `eta_js` facade, its tests, its docs. No
  http_js migration, no `Effect.async` changes, no native-track edits.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e30/` must be committed.
