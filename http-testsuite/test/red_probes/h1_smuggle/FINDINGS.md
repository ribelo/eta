# h1_smuggle Findings

Run:

```sh
nix develop -c dune exec http-testsuite/test/red_probes/h1_smuggle/run.exe
```

## Current Status

All probes in this family pass.

## Fixed Findings

The original H1 pipeline/body-boundary hangs now pass:

- `pipeline_get_get`
- `cl_only_pipeline`
- `cl_too_long`
- `chunked_pipeline`
- `bare_cr_request_line`

`cl_too_short` is classified as safe for the current parser contract: the
server consumes the declared body length and then rejects the malformed
leftover request with 400. The probe accepts `[200]` or `[200; 400]`.

## Passing Coverage Kept

The family continues to cover CL/TE conflicts, duplicate Content-Length,
invalid header syntax, invalid targets, Host validation, and connection-close
smuggling.
