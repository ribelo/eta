# Follow-up 3: DX-E30 — one item: R116 must discriminate (or be reworded)

Only S3 survived verification. Everything else is closed. Keep this round
surgical.

## The gap

R116 claims: "from_js_promise attaches both settlement handlers
synchronously during registration." The current test records that both
arguments are functions when `then` eventually runs — but an adapter that
deferred `meth_call promise "then"` into a later microtask would pass that
test unchanged. The registry policy (AGENTS.md, post-E22) requires the
executable evidence to discriminate the claim; new debt is not an allowed
substitute.

## What to do (pick one, justify in the journal)

**Option A — discriminating test.** Observe *when* the thenable's `then`
runs relative to the runtime's synchronous turn. Two candidate
constructions — validate whichever matches the jsoo runtime's actual
scheduling (state which one and why it discriminates):

1. Marker-in-same-turn: with a recording thenable, initiate
   `Runtime.run` and assert the `then`-invoked marker is already set in
   the same synchronous turn as initiation (i.e., before yielding to host
   microtasks). Deferred attachment leaves the marker unset at that point.
2. Microtask-ordering sentinel: queue a host microtask that asserts the
   marker is already set; per review, "since the runtime body microtask is
   already queued, synchronous registration sets the marker before the
   sentinel; deferred attachment does not." Verify this ordering claim
   against the actual jsoo scheduler before relying on it.

**Option B — reword the claim.** If neither construction can discriminate
on this substrate, narrow R116's registered claim to what IS provable
(e.g., "handlers are attached before any host-observable rejection report
— no unhandled-rejection window", backed by the sentinel) and make the
mli wording match the narrowed claim exactly.

## Protocol

Journal note (which option, why), implement, re-run the mainline js_jsoo
suite and the native trio (the other gates are unaffected — state that),
update LAWS.md R116's evidence pointer or wording, report append, and the
usual signal. Same scope fence. This file stays uncommitted.
