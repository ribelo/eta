# Eta-Primitive-Escape Audit

Run: `bash lib/http/audit/run.sh`
Last updated: 2026-06-28T09:12:16Z
Current sites: 10

## Scope

This audit checks shared `eta_http` for raw Eio concurrency primitives. Shared
HTTP code must express runtime behavior through Eta effects, channels, streams,
runtime services, and backend-neutral protocol helpers. Scheduler-specific
transport loops belong in adapter packages such as `eta_http_eio`.

## Search

```sh
bash lib/http/audit/run.sh
```

The script scans shared OCaml sources for:

```text
Eio.Fiber.fork
Eio.Switch.run
Eio.Promise
Eio.Mutex
Eio.Condition
Atomic.*
```

`Atomic.Portable` is excluded because it is Eta's portable atomic substrate,
not a runtime escape.

## Classification

No raw Eio escape sites are currently allowed in shared `eta_http`.

Current non-Eio sites:

| Site | Pattern | Classification |
| --- | --- | --- |
| `body/stream.ml` | `Atomic.t`, `Atomic.make`, `Atomic.compare_and_set`, `Atomic.set` | Structural shared stream guard; prevents concurrent body-stream operations independently of the selected runtime backend. |

If a future raw Eio site appears, move it into the backend adapter. Add a
shared Eta primitive only when the behavior is genuinely part of Eta's runtime
contract rather than transport-specific implementation detail.
