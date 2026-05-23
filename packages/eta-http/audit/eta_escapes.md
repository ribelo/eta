# Eta-Primitive-Escape Audit

Run: `bash packages/eta-http/audit/run.sh`
Last updated: 2026-05-23T15:08:15Z
Current sites: 0

Sites where eta-http reaches into raw Eio fiber/switch/promise/mutex/
condition primitives or raw `Atomic.t` are listed here. `Atomic.Portable` is
not an escape.

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

No structural escapes yet.

## Debt

| Site | Pattern | Why it is debt |
| --- | --- | --- |

No debt escapes yet.
