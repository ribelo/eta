# Dependency Usage Audit

Run: bash lib/redacted/audit/run.sh
Last updated: 2026-06-28T09:12:16Z
Current sites: 0

Every eta-redacted call site for an allowed external dependency is listed here.
The catalog is not a gate; it is the truth-of-record.

Allowed production dependencies for eta-redacted:

- none beyond OCaml stdlib

Search:

    rg -n -t ocaml 'Eta\\.|Eio\\.|Yojson\\.|Cstruct\\.|Tls\\.' lib/redacted

| Site | Dependency | What | Replaceable? | Replacement cost |
| --- | --- | --- | --- | --- |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
<!-- END DEP_MATCHES -->
