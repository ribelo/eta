# S2 H2 Writer Probe

## Question

Can eta-http drain `ocaml-h2` client write operations into an Eio flow while
preserving `Bigstringaf` iovec slice ownership and reporting partial writes
back to `ocaml-h2`?

## Implementation

- `Eta_http.H2.Writer.cstructs_of_iovecs` converts `Bigstringaf.t H2.IOVec.t`
  slices to `Cstruct.t` views with `Cstruct.of_bigarray`.
- `Eta_http.H2.Writer.write_iovecs` writes those slices with
  `Eio.Flow.single_write`.
- `Eta_http.H2.Writer.drain_client` loops over
  `H2.Client_connection.next_write_operation`, reports `Ok n` after each
  write, and reports `Closed` on writer close.
- `Eta_http.H2.Writer.run_client` drives the same write operations inside an
  `Eta.Effect.t`, using `H2.Client_connection.yield_writer` and
  `Eta.Channel.close` as the wakeup bridge.

## Evidence

```sh
nix develop -c dune runtest packages/eta-http --force
```

Observed:

```text
h2-writer / preserves iovec slices: PASS
h2-writer / drains client preface and request: PASS
h2-writer / blocked write teardown: PASS
```

## Verdict

PASS for the S2 writer-drain cut.

The adapter can write `ocaml-h2` serialized client bytes through Eio without
copying bigstring slices into strings. It can also host the writer loop as an
Eta effect and bridge h2 writer wakeups without raw `Eio.Promise`.

This moves R7 from pure Sans-IO shape toward the Eio adapter. It does not
implement full read-loop integration or public h1/h2 dispatch.

## Disproof Status

| Disproof signature | Status |
| --- | --- |
| H2 writer iovecs cannot be handed to Eio without string copies | Not falsified; `Cstruct.of_bigarray` preserves the iovec slice. |
| `ocaml-h2` write operations cannot be advanced from an Eta-owned writer loop | Not falsified; a real client preface/request drains and reports progress. |
| h2 writer wakeup requires raw `Eio.Promise` | Not falsified; `run_client` uses `Eta.Channel.close` as the wakeup bridge. |
| Blocked writer extends supervised teardown | Not falsified; the blocked-write fixture exits through `Eta.Supervisor.scoped` teardown. |
| Full h2 adapter lifecycle is solved | Still open; read-loop ownership, real socket lifecycle, and public dispatch are not implemented yet. |
