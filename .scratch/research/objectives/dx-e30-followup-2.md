# Follow-up 2: DX-E30 — rework round 2 (packaging + two evidence precision items)

Round 1 fixed the semantic defect. Verification of that fix found one
blocking packaging failure and three precision items. `objective.md` and
`followup-1.md` still apply.

## S1 (blocking) — the migration broke the shipped `eta_http_js` package

`lib/http_js/dune` now links `eta_js`, but the package declaration wasn't
updated: `dune-project` (~line 213) still declares `eta_http_js` with
`eta_jsoo` but no `eta_js`; the generated `eta_http_js.opam` and the
`flake.nix` source-pin list (~line 263) omit it too. Result:

```sh
nix develop .#mainline -c dune build --build-dir=_build-mainline -p eta_http_js @install
# Error: Library "eta_js" not found.
```

Fix all three places (`dune-project` depends, regenerated `.opam`,
`flake.nix` pin list), then prove the exact command above passes. Add that
`-p eta_http_js @install` build to your gate list in the report — the
native shipped gate does not cover mainline-only packages, which is why
this slipped.

## S2 — R117's test does not discriminate

`first_settlement_wins` uses a native `Promise`; JavaScript itself
suppresses the later settlement before the adapter ever sees it, so the
adapter's first-wins logic is untested. Build an adversarial thenable (an
object whose `then(on_ok, on_err)` invokes BOTH callbacks synchronously,
in both orders if practical) and assert: only the winning branch runs, the
loser's mapper/callback never runs. Update the registry row to point at
the discriminating test.

## S3 — R116's evidence doesn't match its claim

The `unhandledRejection` sentinel proves handlers attached *before Node
would report*, not that *both handlers attached synchronously during
registration*. Either make the adversarial thenable observe attach-time
state (e.g., record that both arguments were functions at call time —
that IS the synchronous-attach evidence) or reword R116's claim to what
the sentinel actually proves.

## S4 — missing registry row

The mli sentence "The success type is caller-asserted and unchecked" is a
law-bearing claim with no LAWS.md row. Register it (its evidence is the
contract wording itself plus the `any`-boundary tests — state the
observation boundary honestly per the registry's own rules).

## S5 — document the taxonomy change you shipped

Migration changed one observable behavior: a host fetch returning a
non-thenable used to be a typed `Host_api_error`, now it's `Cause.Die`.
That follows the adapter contract (forged FFI boundary = precondition
violation), but it is a user-visible change for `eta_http_js` consumers.
State it explicitly in the report's rework section and in
`docs/api-dx.md` (or the package README if it has one) — one sentence,
no drama.

## Protocol

Append to your journal (micro-predictions for S1–S5), implement, re-run
ALL gates including the new `-p eta_http_js @install` mainline build,
update report/registry, end with the usual signal. Same scope fence.
This file stays uncommitted.
