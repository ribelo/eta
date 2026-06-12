# handler_fail Red-Probe Findings

Run:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/handler_fail/run.exe
```

## Current Status

All probes pass.

## Fixed Findings

- `h2_stream_read_raise_after_partial`: a streaming response body that raises
  after partial DATA now produces `HEADERS` plus `RST_STREAM`.
- `h2_trailers_construction_raise`: a trailers thunk that raises now resets the
  stream.
- `h2_cancellation_during_response`: response-body cancellation is contained
  and converted to stream failure instead of escaping the H2 server fiber.

## Passing Coverage Kept

- H1 handler construction, response body, stream body, trailers, and
  cancellation failures recover as HTTP/1.1 500.
- H2 handler construction failure returns 500 headers.
- H2 immediate response body thunk failure returns headers plus stream reset.
