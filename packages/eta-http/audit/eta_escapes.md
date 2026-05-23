# Eta-Primitive-Escape Audit

Run: `bash packages/eta-http/audit/run.sh`
Last updated: 2026-05-23T19:11:00Z
Current sites: 1

## What Is NOT An Escape

The following Eio IO leaves are substrate, not Eta-primitive escapes:

- `Eio.Net.*`
- `Eio.Flow.*`
- `Eio.Buf_read.*`
- `Eio.Buf_write.*`
- `Eio.Time.*`
- `Eio.Path.*`

Eta does not own IO leaves. Wrapping them in passthrough Eta types adds
ceremony without semantics.

## Discipline

Every site under the regex is named and classified `Replaceable`,
`Structural`, or `Debt` with a one-line reason. Zero sites is a valid state.
Non-zero sites are valid when classified. Hidden sites are not valid.

Promotion rule: if 3+ `Replaceable` sites share a pattern, file a backlog
task to ship the Eta primitive that absorbs them. The audit then re-scans and
the sites move to zero.

Sites where eta-http reaches into raw Eio fiber/switch/promise/mutex/condition
primitives or raw `Atomic.t` are listed below. `Atomic.Portable` is not an
escape.

Search:

```sh
rg -n -t ocaml 'Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+' packages/eta-http | rg -v 'Atomic\.Portable'
```

## Replaceable

| Site | Pattern | Replacement |
| --- | --- | --- |

No replaceable escapes yet.

## Structural

| Site | Pattern | Why it stays |
| --- | --- | --- |

| `test/test_eta_http.ml:1271` | `Eio.Switch.run` | Structural test harness for an in-memory meter runtime; `eta-test` has no meter-capable fixture helper yet. |

## Debt

| Site | Pattern | Why it is debt |
| --- | --- | --- |

No debt escapes yet.
