# DX-E42a dossier — privacy moves (daemon, Expert, supervisor builders)

Branch: `research/dx-e42a-privacy-moves`. Commits:

- `6bd63296` sealed predictions (journal.md, written before any code change)
- `d0be4038` the move: SPI module, mli deletions, migration, example, docs
- `8ef34a9d` law-registry re-anchor (content-verified)
- this dossier

Sealed predictions: `../journal.md`. Scoring: `../report.md` (and the final
executor message).

## 1. The change in one paragraph

`Effect.daemon` and `Effect.Expert` moved to a single new public module
`Eta.Spi` in the root `eta` library (`lib/eta/spi.ml` + `lib/eta/spi.mli`),
the explicitly unstable service-provider namespace. The nine
`supervisor_{pure,lift,fail,bind,start,await,cancel,failures,check}` builders
left `effect.mli` entirely; `Supervisor` consumes them from the already
private `Effect_supervisor_scope` module through typed bridges added to
`Effect_erasure`. `Effect.supervisor_scoped` and `Effect.supervisor_yield`
stay public as documented low-level primitives (the objective's enumeration
is exactly nine; census predicted −10 vals). `Runtime.drain` stays public:
considered-and-kept per the grill verdict's silence (audit §6.2's
"probably" was not adopted). Implementations moved verbatim; leaf names
(`~leaf_name:"Effect.daemon"`) kept byte-identical, so traces and the
describe snapshot corpus are unchanged.

## 2. The SPI doc block (spi.mli, verbatim)

```ocaml
(** Unstable service-provider interface (SPI) for Eta runtime packages.

    This module is the single home for Eta's service-provider surface: the
    hooks that let runtime and optional backend packages attach operations to
    the current interpreter, plus runtime-owned daemon work.

    - This is not application API.
    - There is no compatibility guarantee: this surface may change or be
      removed in any release and does not carry the stability expectations of
      {!Effect}.
    - Usage requires justification at the runtime-package level: it exists for
      justified Eta library and package implementation support — runtime
      backends, backend-aware leaves, and runtime-owned infrastructure such as
      lifecycle protocols, eviction loops, and protocol readers.
    - It is not for application dependency injection: applications pass
      dependencies as ordinary OCaml values.

    Application code belongs to {!Effect}, {!Supervisor}, and the scoped
    concurrency and resource combinators. *)
```

The four required sentences are present in substance: not application API;
no compatibility guarantee; usage requires justification at the
runtime-package level; not for application dependency injection. The
eligibility clause names justified Eta library/package implementation
support — runtime backends, backend-aware leaves, and runtime-owned
infrastructure — matching the SPI's real consumers (follow-up 1, fix 2).

Surface: `Spi.daemon` (1 val) + `Spi.Expert` (submodule: abstract `context`
type + 13 vals). The daemon doc's two law-bearing sentences moved verbatim
(R41/R42); `make`'s doc now points at `{!Effect}` instead of "this module".

## 3. mli diff summary

`lib/eta/effect.mli` (1182 → 1080 lines):

- Deleted `val daemon` + doc (was 690–700).
- Deleted `module Expert` + trailing doc (was 809–871).
- Deleted the nine supervisor Scope builders (was 725–750).
- Kept `supervisor_scoped`, `supervisor_yield` (doc adjusted to singular),
  and all supervisor types (publicly aliased by `supervisor.mli`).
- Kept the header facade comment byte-identical, so registry rows above the
  deletions do not drift.
- One cross-reference fix inside `with_clock`'s doc:
  `{!Expert.contract}` → `{!Spi.Expert.contract}`.

`lib/eta/runtime.mli` / `lib/eta/runtime_contract.mli`: `[Effect.Expert]` →
`[Spi.Expert]` doc references (in place, no line drift).

`lib/js_stream/eta_js_stream.ml` consumes the SPI as `Eta.Spi.Expert`
directly with an explicit `eta` dependency (`lib/js_stream/dune`,
`dune-project`, regenerated `eta_js_stream.opam`). The `eta_js` facade does
NOT re-export the SPI (follow-up 1, fix 1: one namespace, no second
application-facing locator).

`lib/eta/supervisor.mli`: unchanged.

## 4. Mechanics chosen (the review's judgment call)

- **One namespace**: `Eta.Spi` in the root library. Consumers (~10 lib files
  across `eta`, `eta_blocking`, `eta_cache`, `eta_http`, `eta_http_eio`,
  `eta_js_stream`, `eta_otel`, `eta_signal`, `eta_stream` + tests) already
  depend on `eta`: zero dune/opam dependency edits. Rejected: separate
  public library (dependency churn for every consumer, against constraint
  (c)); `Effect.Spi` submodule (stays inside the namespace the audit
  flagged); `Private`/`Unsafe_runtime_extension` names (the module must be
  public; nothing here is memory-unsafe).
- **`Expert` stays a named subgroup** inside `Spi`: call-site churn is one
  token (`Effect.Expert.X` → `Spi.Expert.X`; `lib/blocking` needed a single
  alias-line edit), and the doc grouping survives.
- **Supervisor bridging**: the sealed facade makes `Effect.supervisor_scope`
  nominally distinct from the private GADT, so `Effect_erasure` gained five
  typed `%identity` bridges (scope both ways, scope-with-child result,
  supervisor, child) plus ten thin builder wrappers — the module whose
  stated job is exactly this ("the audited bridge from private eff
  constructors to the public abstract Effect.t"). `supervisor.mli` keeps its
  public manifest aliases, and `Effect.supervisor_scoped` still composes
  with `Supervisor.Scope` builders. Alternative considered and rejected:
  making `Supervisor`'s types abstract (fewer casts, but narrows a public
  manifest and breaks that composition path — more than a namespace move).
- **Nine, not eleven**: the objective enumerates nine vals and predicts
  −10; `supervisor_scoped`/`supervisor_yield` remain documented low-level
  primitives in the same category as `bind`/`(>>=)`. Moving them too would
  deviate from the sealed census for ~4 lines of benefit; flagged here so
  the review can ask for the follow-up if it disagrees.

## 5. Example before/after

Before (`examples/daemon_drain.ml`, deleted): taught `Effect.daemon` +
`Runtime.drain` as application API — a daemon waiting on a release promise,
drained from outside the runtime.

After (`examples/background_shutdown.ml`): the audit §6.2 pattern — the
long-lived worker belongs to the explicit top-level application scope.
`Effect.with_background` owns the worker; the body signals stop and
explicitly awaits the worker's completion inside the scope; no daemon, no
`Runtime.drain`, no invisible runtime-owned world. Same started/before/after
assertions and print shape as the old example.

Wiring: `examples/dune` (stanza+alias), `examples/README.md`,
`test/api_dx/api_dx_surface.ml` file list, `docs/api-dx.md` (example list,
command list, area prose, daemon paragraphs, surface map),
`docs/background-work.md` (SPI pointer replacing the `Effect.daemon`
recommendation). `test/api_dx/api_dx_examples.ml`: area renamed
`daemon_drain` → `background_shutdown` (area count stays 64); the manual
`Eio.Fiber.fork_daemon`/`Atomic` snippet stays as the "current"
anti-pattern; the "proposed" snippet and compilable helper teach
`with_background` + in-body wait; assertions require
`Effect.with_background`=1 and `Effect.daemon`/`Runtime.drain`=0.
`docs/services.md` deliberately untouched (it never named Expert; its
runtime-services framing already matches).

## 6. Census

`Effect.mli` public surface:

| metric | before | after | delta |
| --- | ---: | ---: | ---: |
| public vals | 129 | 119 | −10 |
| public submodules | 1 (`Expert`) | 0 | −1 |
| public types | 7 | 7 | 0 |
| top-level SPI modules | 0 | 1 (`Spi`) | +1 |

SPI surface (`lib/eta/spi.mli`): `daemon` (1 val) + `Expert` (1 submodule:
1 abstract type + 13 vals) = 14 vals total. No `Eta_js` re-export: the JS
facade does not alias the SPI (follow-up 1, fix 1).

Sealed prediction was −10 vals −1 submodule +1 SPI module: exact match.

## 7. Footguns

−1/+0 as predicted. Removed: public `Effect.daemon` presenting a second
execution model (result outside the typed channel, separate `drain`
workflow) as application API. `Effect.Expert` → `Spi.Expert` is counted as
the same move's framing fix, not a second footgun. Nothing new introduced:
`Spi` is not autocomplete-adjacent to `Effect`, and its doc block says what
it is at the point of hover.

## 8. Law registry diff (`.scratch/research/dx/e22/review/LAWS.md`)

Re-anchored with a content-verifying script (old span text must equal new
span text; the one intentional difference is the `{!Spi.Expert.contract}`
cross-reference inside R88/CD-E22-011 spans):

- R41, R42: `effect.mli:698-700` → `lib/eta/spi.mli:27-29` (claims and
  registered tests unchanged).
- CD-E22-018: `effect.mli:814-872` → `lib/eta/spi.mli:31-96`; cluster
  renamed `Effect.Expert` → `Spi.Expert`; debt terms (owner, follow-up,
  2026-09-15) unchanged.
- Pure line drift (claims/text unchanged): 16 M-rows (M28–M44), 17 R-rows
  (R87–R93, R112–R115, R166a–R166h), 6 CD-rows (CD-E22-010/011/012/013/014/017).
- Rows above the deletions untouched by construction (header comment kept
  byte-identical): M25–M27, R38–R40, R138–R145, R109, etc.
- Census totals: `effect.mli` 120→118 registered, 183→181 covered; new
  `lib/eta/spi.mli` row 0/2/2; totals hold at 116/169/2/285 (cross-checked
  by column sums).
- No supervisor rows existed (the builders' docs carry no law-bearing
  claims); no orphans; no new debt; no deleted claims.
- The four-sentence SPI prose is compatibility/usage policy, not behavior —
  classified non-law-bearing, no row required; the daemon doc's law
  sentences stayed covered via R41/R42.

## 9. Red-team note (T2: does the wrong thing look wrong?)

Probe (throwaway, not committed): an application-shaped file under
`examples/` with `open Eta`.

1. `Effect.daemon (Effect.sync ...)` → **compile error**:
   `Unbound value "Effect.daemon"`.
2. `Effect.Expert.make ~leaf_name (fun _ctx -> ...)` → **compile error**:
   `Unbound module "Effect.Expert"`.
3. `Spi.daemon ...`, `Spi.Expert.make` + `runtime_service` service-locating,
   and `Spi.Expert.eval` inline-eval → **compiles** (expected: OCaml
   visibility cannot forbid a public module).

Assessment: the facade is now honest — the old spellings are hard errors
and `Effect.` autocomplete no longer offers daemon/Expert. Using the SPI
requires deliberately writing `Spi.`, a namespace that reads as
service-provider machinery, and the hover shows the four sentences
("This is not application API… not for application dependency injection")
at the exact point of temptation. `runtime_service` behind `Spi.Expert` is
strictly less inviting than behind `Effect.Expert`; nothing in the new
shape is more inviting to locator behavior than before. Enforcement was
never available; the win is that the wrong thing now looks wrong.

Adjacent unchanged surface (out of E42a scope, recorded for completeness):
`Runtime_contract.create_service_key` remains public-advanced API for
runtime packages; the audit's concern was Expert's location, not the
contract itself.

## 10. Behavior parity

- `test/effect_introspection/expected_descriptions.txt`: zero diff
  (leaf_name kept; `describe` corpus stable).
- Full native suite green with only namespace token swaps in tests; the
  single non-swap test change is the deliberate api_dx
  `daemon_drain` → `background_shutdown` docs-metrics rework (the required
  example migration, not a behavior expectation).
- No semantic change to any implementation: `daemon_internal`, `Expert`,
  and the supervisor builders moved verbatim; `Eta.Spi.daemon` is the old
  `Effect.daemon` behind `%identity` erasure casts at the module boundary.

## 11. Gates

| gate | result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS (0 FAIL/Fatal across the full log) |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo test/signal_jsoo test/http_js` | PASS (plus explicit `lib/js_stream lib/js`) |
