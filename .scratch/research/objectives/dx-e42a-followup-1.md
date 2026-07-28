# Follow-up 1: DX-E42a — promote-with-fixes; three precise fixes

Independent review verdict: the design is sound, three inconsistencies
block promotion. All three are small and precisely specified. Record the
work as a short journal amendment (no new full prediction set needed).

## Fix 1 — remove the public `Eta_js.Spi` alias

`lib/js/eta_js.ml{,i}` re-exports the SPI, creating a second
application-facing locator solely because `eta_js_stream` consumes it.
That contradicts the experiment's one-namespace constraint and weakens
the quarantine the batch exists to create.

- Delete the `Spi` alias from `lib/js/eta_js.ml` and `lib/js/eta_js.mli`.
- `lib/js_stream/eta_js_stream.ml` uses `Eta.Spi.Expert` directly.
- Declare `eta` in `lib/js_stream/dune` (and the `eta_js_stream` package
  dependencies if the opam metadata needs it).
- Update your census (the `eta_js +1 alias` line) and the law registry if
  any row anchored to the alias.

## Fix 2 — SPI eligibility doc must match its real consumers

`lib/eta/spi.mli` currently limits justification to "packages that
implement or extend a runtime backend" — but the repository itself
consumes the SPI from `eta_cache`, `eta_signal`, `eta_http`,
`eta_stream`, and protocol clients: backend-aware leaves and lifecycle
protocols, not runtime backends. A fence that forbids its own legitimate
users is exactly the doc-vs-reality mismatch this programme exists to
kill.

Rewrite the eligibility sentence(s) to describe **justified Eta
library/package implementation support** — including runtime backends,
backend-aware leaves, and runtime-owned infrastructure — while keeping
the strong "not application API / not for dependency injection" language
verbatim in substance.

## Fix 3 — the example's reversed ordering assertion

`examples/background_shutdown.ml:60` asserts
`"worker completed after scope exit"` while the example's own comment
(lines 44–47) correctly teaches that the worker completes BEFORE scope
exit — the lifecycle ordering the example exists to teach. Move the
completion assertion inside the `with_background` body after awaiting
`done_`, or at minimum correct the label to "before scope exit". The
example must assert what it demonstrates.

## Also recorded (not required for this batch)

- The `%identity` invariant is audited, not compiler-enforced — the
  erasure surface must not spread further.
- `supervisor_scoped`/`supervisor_yield` should eventually follow the
  nine: a future experiment makes `Supervisor` own the public supervisor/
  child/scope/body types directly over the private representation and
  eliminates the five erasures rather than adding two more. Registered
  as follow-up F-E42a-1 in your journal.
- The executor's parity claim was qualified: `test/api_dx/api_dx_examples.ml`
  intentionally changes meaning (daemon/drain → scoped shutdown). Note it
  in the report's parity section.

## Gates

Re-run the full set after fixes (native trio + mainline JS targets incl.
`lib/js_stream` and `lib/js`, `--build-dir=_build-mainline`).

## Report

Append: the three fixes, gate results, and your final recommendation.

## Done means

Same signals: `E42A READY FOR REVIEW` / `E42A BLOCKED: <reason>` /
`E42A STOP: <§4.6>`. Same scope fence. This file stays uncommitted.
