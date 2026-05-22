# Eta Dogfood Gaps Found By Pool Survival

## G1 - Scoped cancellation inside all_settled can surface as Die

Fixture: runtime_smoke.ml, cancel_waiter.

Expected: a waiter under Effect.timeout should be observable as a typed Timeout
or a caught cancellation result, while the acquire wait slot is cleaned.

Observed before the timeout-choice fix: both branches cleaned the wait slot, but
Effect.all_settled recorded the waiter as Cause.Die containing nested
Eta__Runtime.Raised_cause exceptions.

Status: fixed for the reproduced pool smoke and covered by focused Eta
regressions. packages/eta/runtime.ml now normalizes internal Raised_cause
exceptions in Catch/Tap_error and normalizes timeout/cancellation races in
Timeout. packages/eta/test/test_eta.ml includes "all_settled timeout scoped
resource typed" and "nested timeout maps outer timeout". Rerunning
scratch/eta_research/pool_survival/runtime_smoke.exe passes both pool branches.

Impact: this is no longer an open primitive gap, but it remains an important
regression class for future cancellation work.

## G2 - Eta lacks a public cancellation-safe wait-slot primitive

The lab had to hand-roll waiter registration, retry sleep, finalizer cleanup,
normal-vs-cancelled distinction, and stats. This is too subtle to copy into
eta-http, eta-sql, eta-grpc, and eta-llm.

Likely Eta work: expose a small scoped wait-slot or bounded admission primitive,
or ship it inside Eta.Pool.

## G3 - Idle eviction needs package-owned daemon behavior

Both branches use Effect.Private.daemon for idle eviction. That is fine for a
module implemented inside packages/eta, but bad as application recipe code.

If Pool stays eta-http-private, eta-http either uses Private or owns raw Eio
fibers/switches outside Eta. That weakens the boundary V-Rs preserved for
Resource.auto.

## G4 - The portable atomic API is Portable.Atomic, not Atomic.Portable

Fixture: atomic_portable_negative.ml.

Observed: Atomic.Portable is an unbound module. oxmono and the installed
libraries use Portable.Atomic, and portable_atomic_positive.ml verifies a
Treiber LIFO stack using that API.

Impact: this is no longer a primitive gap. It is a naming/import correction.
Eta already depends on the portable package, so Eta.Pool can use
Portable.Atomic if the stored connection metadata satisfies the portable and
contended mode requirements.

## G5 - Direct conn local unique cannot be produced from pool storage

Fixture: oxcaml_conn_unique_negative.ml.

Observed: the compiler correctly rejects passing a connection read from an
aliased pool slot as unique.

Impact: the exact API "conn @ local unique -> effect" does not fit current
storage. A sealed borrow handle can be local unique, but the underlying
connection remains global/aliased inside the pool.

## G6 - Local borrow handles do not compose with lazy Eta effects

Fixture: oxcaml_borrow_effect_capture_negative.ml.

Observed: an abstract local borrow cannot be captured by Effect.sync because
the closure stored in Effect.t must be global.

Impact: a local-unique borrow API is promising for synchronous stack-scoped
operations, but current Eta Effect.t cannot express effectful operations that
capture the local borrow. Eta would need a local-aware effect representation or
a different synchronous callback boundary before this becomes the main Pool API.

## G7 - Timeout typing is awkward

Effect.timeout requires the input effect's error type to already include
Timeout. In the pool lab, the common pool error type had to include Timeout
even though only deadline-wrapped operations produce it.

The timeout-choice lab hit the same issue: eta-http can map raw Timeout into
connect_timeout, tls_handshake_timeout, response_header_timeout, and body-idle
errors with local wrappers, but the base error type still has to admit raw
Timeout.

Impact: APIs that optionally accept deadlines either pollute their base error
type with timeout or need local wrappers at every call site. Eta should add a
typed helper such as Effect.timeout_as so callers can say which error value a
deadline should produce without exposing raw Timeout in the wrapped effect.

## G8 - Allocation signal is non-trivial

allocation_probe.exe runs 1,000 sequential acquire/use/release cycles:

~~~text
branch_a_internal_pool minor_words=516553
branch_b_eta_pool      minor_words=515883
~~~

This is roughly 516 minor words per acquire/use/release in this lab. It is not
a production benchmark, but it is enough to say Eta pool hot paths need a real
benchmark before claiming low-allocation behavior.

## G9 - Observability needs a first-class shape

The lab uses an Eio.Stream of event names and a stats snapshot. Real Eta.Pool
should emit Eta metrics/traces/logs through runtime capabilities, with stable
stats names for active, idle, waiting, opened, closed, health-rejected, and
cancelled waiters.

## G10 - Raw Portable.Atomic ergonomics leak mode friction

Fixture: scratch/eta_research/pool_choice/pool_protocol_bench.ml.

Observed: the first full-protocol Treiber implementation failed when ordinary
integer comparisons consumed values returned by Portable.Atomic.get. Those
values are contended. The compiling version uses portable integer atomics for
connection flags and timing fields, and reads counters through atomic fetch
operations rather than treating them as plain local ints.

Impact: Eta.Pool can use Portable.Atomic, but the implementation should hide
counter/flag/timestamp mode details behind a small private helper layer. Eta
users should not have to learn this mode friction from a public Pool API.

## G11 - Portable.Atomic cannot store arbitrary eta-http connection payloads

Fixture: scratch/eta_research/pool_choice/portable_atomic_eio_conn_negative.ml.

Observed: a Treiber stack over Portable.Atomic can store portable fake
connections, but it rejects an Eio-shaped connection record because the Eio
stream field is nonportable and compare_and_set requires a portable replacement
value.

Impact: a public generic Eta.Pool over arbitrary connections should not use
Portable.Atomic for the connection payload unless the API explicitly constrains
the payload to portable. eta-http v1 should keep Pool same-domain and use mutex
LIFO for idle connection storage. Portable.Atomic is still appropriate for
private counters, flags, and a future portable-payload pool.
