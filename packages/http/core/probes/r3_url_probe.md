# R3 URL Parser Probe

Hypothesis: eta-http can parse the RFC 3986 client subset in-tree without the
`uri` dependency.

Scope:

- absolute `http` and `https` URLs;
- authority with host and optional port;
- path, query, and fragment;
- no userinfo;
- no decoding or normalization beyond lowercasing host access.

Disproof signature from `OBJECTIVE.md`: parser grows past roughly 3000 LOC,
which would reopen the `uri` dependency decision.

Verdict: PASS for the size and dependency part of R3.

Evidence:

```sh
nix develop -c dune runtest packages/eta-http --force
```

The parser lives in `packages/eta-http/core/url.ml` and is under the R3 size
ceiling. It stores spans into the original string and copies component strings
only through accessors such as `host`, `path`, and `origin_form`.

Residual risk:

- Allocation claims are limited to the parser shape. The public API still
  allocates the result record and accessors allocate returned strings.
- IDNA normalization is delegated to the TLS/X.509 hostname path in S1
  transport work.
