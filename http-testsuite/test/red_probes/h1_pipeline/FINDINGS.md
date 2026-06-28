# h1_pipeline Findings

Run:

```sh
nix develop -c dune exec http-testsuite/test/red_probes/h1_pipeline/run.exe
```

## Current Status

All probes pass.

## Fixed Findings

- `handler_exception_then_valid`: handler exceptions now produce a 500 response
  and close the connection, so a pipelined follow-up request is not processed.
- `handler_timeout_then_valid`: handler timeout now produces 503 and closes the
  connection.

## Passing Coverage Kept

- `pipeline_two_ok`
- `malformed_then_valid`
- `unread_body_drain_small`
- `unread_body_drain_large`
- `unread_body_reset`
- `partial_body_then_request`
