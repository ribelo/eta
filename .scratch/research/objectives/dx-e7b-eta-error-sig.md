# Objective: DX-E7b — `[@@deriving eta_error]` signature generator + escape-hatch evidence (retro-review rework)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e7b`
- Branch: `research/dx-e7b-eta-error-sig` (already checked out here; do not create others)
- Origin: retro review of E7 found the deriver cannot generate `.mli` signatures (verified by executable probe), an untested escape hatch, an overstated contract, and two slop examples
- Evidence IDs: `V-DX-E7B-*` (orchestrator log); your journal is the branch record

## Executor profile

ppxlib deriver work: a `sig_type_decl` generator mirroring the existing
`str_type_decl` one, a paired .ml/.mli consumer test, and an expansion
test for the previously-untested `[@eta.render]` escape hatch. Small,
precise, evidence-first. Plus two example reversions.

## The findings to fix (all verified by the orchestrator)

1. **No signature generator.** `lib/ppx/ppx_eta.ml` registers only
   `~str_type_decl`. In an `.mli`, `[@@deriving eta_error]` fails with
   "not a supported signature type deriving generator". AGENTS.md keeps
   public APIs in `.mli` files — the deriver is a half-feature without
   this.
2. **Untested escape hatch.** `test/ppx_expansion/cases/h_override.ml`
   applies `[@eta.render]` to `string`, a built-in — it tests nothing
   about the escape path. Add a case with a NON-built-in payload (e.g. a
   record) + a custom `pp` via `[@eta.render]`, accepted; and the same
   payload without the attribute, rejected with the what/where/what-next
   message.
3. **Overstated contract.** The deriver rejects inherited rows and
   private aliases too; the actual contract is "public, explicit-tag
   closed rows". State exactly that (docs + the rejection messages where
   they speak of "closed").
4. **Slop examples.** `examples/map_projection.ml` invents
   `` `Unexpected `` for an infallible `Effect.pure` program;
   `examples/channel_probe.ml` invents `` `Impossible ``. Delete the
   invented types, the `@@deriving`, and any `pp_err` wiring in those
   files; if a span genuinely needs a renderer there, hand-write it —
   otherwise nothing.

## Protocol

1. **Seal your predictions** in `.scratch/research/dx/e7b/journal.md`
   before any code change (`docs(dx-e7b): seal predictions`).
2. **Docs-first:** the `.mli` contract for the sig generator's output
   (`val pp_err : Format.formatter -> err -> unit`) and the contract
   precision (public, explicit-tag closed rows).
3. **Implement:**
   - `sig_type_decl` generator in `lib/ppx/ppx_eta.ml`, mirroring the
     structure generator's naming/shape.
   - Paired consumer test: a module deriving in BOTH `.ml` and `.mli`,
     with `pp_err` used through the interface (proves the .mli path).
   - New expansion cases per finding 2 (accept + reject), snapshots
     updated (the corpus is pinned to `5.2.0+ox`).
   - Contract precision per finding 3.
   - Example reversions per finding 4.
4. **Gates** (from the worktree, exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   ```
   Also verify manually: a fresh `.mli` using `[@@deriving eta_error]`
   compiles, and `pp_err` is usable through the interface.
5. **Report** in `.scratch/research/dx/e7b/report.md`: the probe from
   finding 1 re-run green, the new expansion cases, the example
   reversions, gates, predictions scored, and your recommendation.

## Done means

Your final message ends with exactly one of:

- `E7b READY FOR REVIEW`
- `E7b BLOCKED: <reason>`
- `E7b STOP: <§4.6 stop condition>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md`, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E7b's surface: `lib/ppx/`, `test/ppx_*`, the two examples,
  docs for the deriver. Do NOT extend the deriver's payload support
  (inherited rows, private aliases) — document, don't expand.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e7b/` must be committed.
