# DX-E32 Journal — `fold ~ok:Fun.id` usage-data re-check

Branch: `research/dx-e32-fold-recheck`
Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e32`

## Predictions (sealed before census)

This file is the immutable pre-investigation record. Wrong predictions remain
as data; execution evidence and scoring belong in `census.md` and `report.md`.

### Decision question and proof obligations

Decide whether demonstrated recovery-only frequency earns `recover` as a
documented special case of `fold`, without recreating E23's exception-catching
misreading.

| ID | Proof question | Evidence needed | Predicted result |
|---|---|---|---|
| P1 | Is the claimed frequency real and consumer-shaped? | Exact and variant census, with file/site classifications | Yes: 26 sites in 10 files, including the stated six example files; at most two additional identity-lambda variants |
| P2 | Is `recover` exactly a shorthand rather than new behavior? | Signature/implementation inspection and, if B, parity tests over success, typed failure, defect, and interruption | Yes; exact parity with `fold ~ok:Fun.id ~error:f` is straightforward |
| P3 | Does the name remain safely typed-channel-specific to a newcomer? | Adversarial exception-misreading review against the proposed val and contract | No: the contract corrects the model after reading, but the bare name still plausibly promises exception recovery before the contract is read |
| P4 | Can B honestly claim concepts stay flat while vals rise? | Handle-cluster count and progressive-disclosure argument | Partly: 10 → 11 vals is objective; concept count can remain flat only when `recover` is always taught and cross-referenced as `fold` shorthand, but the exception association makes that framing weaker than E20's friendly special cases |

### Census prediction

- Exact `fold ~ok:Fun.id ~error:...` recovery-only uses: **26 sites / 10
  files**.
- Variant search (`fun x -> x`, one-case `function`, and multiline formatting):
  predict **zero missed semantic sites**, with an uncertainty band of 0–2.
- File shape: **6 example files / 4 non-example files**, as inherited from the
  assignment.
- Site shape: predict both required classes are present. Constant defaults will
  be a minority (roughly 8–12 sites); functions that inspect or transform the
  error will be the majority (roughly 14–18 sites).
- Consumer shape: predict a clear majority of sites are consumer-shaped because
  examples account for most teaching pressure, while framework/internal sites
  remain a meaningful minority.

### Candidate ledger and predicted verdict

| Candidate | Strongest case | Evidence needed to win | Predicted status |
|---|---|---|---|
| A — keep `fold` only | One both-channel concept and no exception-flavored alias; E23's naming fix remains intact | Frequency is weak, or adversarial review still reads `recover` as exception-catching | **Accepted (predicted)** |
| B — restore `recover` as `fold` shorthand | ≥20 repeated recovery-only sites, especially teaching code, justify progressive disclosure without semantic growth | Confirmed consumer frequency, exact parity, and no reopened exception misreading | Rejected on the decisive naming gate despite passing frequency/parity (predicted) |
| C — another name or shape | Could theoretically remove syntax without the old association | Evidence that neither A nor the specified B fits | Out of scope / not predicted |

Prior: **A 0.60 / B 0.38 / C 0.02**. I predict the census strongly supports B,
but the red-team review still produces the newcomer story “use `recover` around
`Effect.sync (fun () -> failwith ...)`”. The proposed typed-channel sentence
explains why that is wrong, yet does not prevent the expectation created by the
name itself. Under the pre-registered decisive gate, **A holds**.

### Review and red-team prediction

The deliberate exception misuse will surface `Exit.Error (Cause.Die _)`; no
typed recovery function runs. A careful reader of the full contract will answer
correctly. A scanning newcomer seeing the val and the familiar word `recover`
can still choose it for a `failwith`, so I predict the orchestrator's decisive
review will find the E23 misreading reopened.

For A's opposite-direction red team, `fold ~ok:Fun.id` is noisy but semantically
specific: it may slow comprehension and over-emphasize the unchanged success
path, but it does not suggest that defects are caught. I predict no distinct
wrong semantic reading that `recover` would prevent—only avoidable ceremony.

### Delta predictions

If A (predicted):

- handle cluster: **10 → 10 vals**, concepts unchanged;
- public surface and implementation: **0 code delta**;
- call sites: **0 migration delta**;
- footguns: **+0**, retaining syntactic noise as the known cost.

If B unexpectedly passes review:

- handle cluster: **10 → 11 vals** while claiming the same concept count;
- implementation: one line plus docs/tests/law row;
- call sites: all qualifying sites migrate, approximately 26 removals of
  `~ok:Fun.id`;
- footguns: predicted **+1 naming trap** unless review demonstrates that the
  cross-referenced contract prevents rather than merely repairs the exception
  expectation.

### What would change the prediction

B should win if a blinded/newcomer review consistently identifies `recover` as
typed-failure-only from the proposed surface at selection time—not merely after
being shown the explanatory paragraph—and the census confirms at least 20
consumer-shaped sites. A should also win if the frequency claim falls below the
pre-registered threshold. C requires stopping for orchestrator direction.
