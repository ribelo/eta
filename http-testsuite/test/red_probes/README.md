# Red Probes for eta_http / eta_http_eio

This directory contains opt-in adversarial probes that are intentionally
allowed to fail. They exist to find bugs, not to assert correctness.

Each probe family lives in its own subdirectory and is responsible for:
- Starting an Eta HTTP server (H1, H2C, or HTTPS)
- Driving it with malicious or pathological input
- Reporting whether the server behaved safely within a deadline

A "finding" is any probe where Eta:
- hangs past the deadline,
- leaks an uncaught exception,
- crashes the server fiber,
- reuses a connection that policy says must close,
- accepts a request that should be rejected,
- produces an unbounded resource (memory, FDs, streams),
- or otherwise diverges from documented Eta policy.

Probes are not fixes. When a probe finds a bug, minimize the repro and
record it in `FINDINGS.md` in this directory.

## Output format

Each probe family executable must print lines like:

```
probe <name> <status> [<detail>]
```

where `<status>` is one of `PASS`, `FAIL`, `HANG`, `CRASH`, `POLICY_GAP`.
A probe family may also write a `FINDINGS.md` file with structured findings.

## Running

```sh
dune build @red-probes
```

or individually:

```sh
dune exec http-testsuite/test/red_probes/h1_smuggle/run.exe
```

## Findings classification

- confirmed Eta bug
- likely Eta bug
- ambiguous policy gap
- harness/reference issue
