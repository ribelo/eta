# P1b Direct `Effect.acquire_release` Results

P1a compared pre-wrapped CPS resources. P1b covers the missing case: real sites
where code calls `Effect.acquire_release ~acquire ~release` directly and then
uses the acquired value in a body.

## Sites

| Site | Source shape | Release timing | Counts toward companion win? |
| --- | --- | --- | --- |
| `lib/eta/semaphore.ml` `with_permits` | `Effect.scoped (Effect.acquire_release ... |> Effect.bind (fun () -> f ()))` | Body-bounded. Release after `f ()`. | Yes |
| `lib/eta/pubsub.ml` `subscribe` | `Effect.scoped (Effect.acquire_release ... |> Effect.bind f)` | Body-bounded. Release after subscriber body. | Yes |
| `lib/http/body/source.ml` `with_owned_stream` | `Effect.scoped (Effect.acquire_release ... |> Effect.bind (fun owned -> f ...))` | Body-bounded. Release after body stream use. | Yes |
| `lib/eta/pool.ml` `with_acquire_guard` | Guard finalizer disarmed or updated by later acquisition steps. | Scope-end guard semantics matter. | No |
| `mixed.consumer.with_and_direct` | Pre-wrapped `with_client`/`with_monitor` plus direct stream acquire. | Body-bounded direct stream. | Yes |

## Metrics

Command:

```text
nix develop -c _build/default/scratch/eta_research/let_at_and_with_resource/p1b_direct_acquire.exe
```

Result:

```text
semaphore.with_permits H-A applicability=body-bounded lines=5 avg_indent=2.80
semaphore.with_permits H-B applicability=body-bounded lines=5 avg_indent=3.40
semaphore.with_permits H-C applicability=body-bounded lines=9 avg_indent=2.67
semaphore.with_permits H-D applicability=body-bounded lines=7 avg_indent=3.86
pubsub.subscribe H-A applicability=body-bounded lines=5 avg_indent=2.80
pubsub.subscribe H-B applicability=body-bounded lines=5 avg_indent=3.40
pubsub.subscribe H-C applicability=body-bounded lines=9 avg_indent=2.67
pubsub.subscribe H-D applicability=body-bounded lines=7 avg_indent=3.86
body_source.with_owned_stream H-A applicability=body-bounded lines=5 avg_indent=2.80
body_source.with_owned_stream H-B applicability=body-bounded lines=5 avg_indent=3.40
body_source.with_owned_stream H-C applicability=body-bounded lines=9 avg_indent=2.67
body_source.with_owned_stream H-D applicability=body-bounded lines=7 avg_indent=3.86
pool.with_acquire_guard H-A applicability=scope-end-required lines=5 avg_indent=2.80
pool.with_acquire_guard H-B applicability=scope-end-required lines=5 avg_indent=3.40
pool.with_acquire_guard H-C applicability=scope-end-required lines=9 avg_indent=2.67
pool.with_acquire_guard H-D applicability=scope-end-required lines=7 avg_indent=3.86
mixed.consumer.with_and_direct H-A applicability=body-bounded lines=8 avg_indent=3.50
mixed.consumer.with_and_direct H-B applicability=body-bounded lines=8 avg_indent=2.25
mixed.consumer.with_and_direct H-C applicability=body-bounded lines=11 avg_indent=2.18
mixed.consumer.with_and_direct H-D applicability=body-bounded lines=9 avg_indent=3.33
```

## Interpretation

- H-B does not reduce line count versus H-A on direct acquire sites, but it replaces value-returning acquire/bind with a body-bounded resource callback.
- H-C makes direct acquire sites worse unless the consumer writes a local `with_*` wrapper around every `acquire_release`.
- H-D saves two lines against H-C on each direct body-bounded site and on the mixed consumer fixture because `let@` can bind the companion directly.
- `pool.with_acquire_guard` is the control: the guard finalizer is deliberately tied to the surrounding scope and can be disarmed or replaced downstream. Even if the companion exists, this site should stay value-returning.

Verdict impact: P1b supplies a real H-D win on 4 body-bounded sites. The companion should be accepted with `Effect.with_resource` as the name from P4.
