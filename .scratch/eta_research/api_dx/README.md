# Eta API DX research

This lab starts from user-facing examples rather than deletions. The goal is to
prove what a better Eta API should look like before deciding whether any current
surface is dominated.

Success criteria for this bucket:

- examples cover HTTP handlers, resource workflows, retries, streams, tests, and
  small CLI/business logic;
- current-style and proposed-style functions type-check;
- proposed examples reduce explicit `Effect.bind` visibility without hiding
  lifecycle, typed errors, retry, concurrency, or observability semantics;
- any promoted production API must be a small helper or adapter justified by
  more than one example.

Run:

```sh
dune runtest test/api_dx --force
```

User-facing examples promoted into the real workspace live under
`examples/`. Build and test them with:

```sh
nix develop -c dune build @examples
nix develop -c dune runtest examples --force
```
