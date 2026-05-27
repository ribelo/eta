# S2 H2 Read Adapter Probe

## Question

Can eta-http feed an Eio source into a real `ocaml-h2` client connection and
deliver a server response when frame bytes arrive in small chunks?

## Implementation

- `Http.H2.Multiplexer.create_client_reader` owns a reusable
  `Bigstringaf.t` read buffer and pending parser offset/length.
- `Http.H2.Multiplexer.read_client_once` feeds pending bytes to
  `H2.Client_connection.read`, compacts unconsumed bytes, reads more bytes
  from `Eio.Flow.single_read`, and sends EOF through
  `H2.Client_connection.read_eof`.
- The focused test builds a real in-process `H2.Client_connection` and
  `H2.Server_connection`, writes a client request through
  `Http.H2.Writer.drain_client`, feeds it to the server, drains the
  server response, then reads the response back through an Eio source split
  into 7-byte chunks.

## Evidence

```sh
nix develop -c dune runtest lib/http --force
```

Observed:

```text
h2-multiplexer / reads server response: PASS
```

## Verdict

PASS for the S2 read-adapter cut.

The adapter can drive real `ocaml-h2` client read state from Eio source
bytes and preserve incomplete frame prefixes across reads. This advances R7
beyond the P1 pure Sans-IO probe.

It does not close the full h2 multiplexer. Wakeup registration, owner-fiber
lifecycle, public request dispatch, h2 stream-permit body release, typed error
mapping, GOAWAY admission, and security attack fixtures still remain in S2.

## Disproof Status

| Disproof signature | Status |
| --- | --- |
| `ocaml-h2` requires all frame bytes to arrive in one read buffer | Not falsified; 7-byte Eio chunks deliver a response successfully. |
| Parser zero-progress on incomplete frame prefixes makes small reads unusable | Not falsified; pending bytes are compacted and retried after more source bytes arrive. |
| Eio source EOF cannot be propagated through `ocaml-h2` client read state | Not falsified for this fixture; EOF is represented through `read_eof`. |
| Full R7 Eio lifecycle is closed | Still open; wakeups, cancellation, dispatch, and typed error mapping are not implemented yet. |
