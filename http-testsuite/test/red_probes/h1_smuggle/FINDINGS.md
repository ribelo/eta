# h1_smuggle Findings

Run:

```sh
nix --option eval-cache false develop -c dune exec http-testsuite/test/red_probes/h1_smuggle/run.exe
```

## Current Status

Most probes pass. The remaining non-PASS case is a policy gap:

- `bare_cr_request_line`: a request line ending in bare CR waits for the
  request-header timeout instead of receiving an immediate 400.

## Fixed Findings

The original H1 pipeline/body-boundary hangs now pass:

- `pipeline_get_get`
- `cl_only_pipeline`
- `cl_too_long`
- `chunked_pipeline`

`cl_too_short` is classified as safe for the current parser contract: the
server consumes the declared body length and then rejects the malformed
leftover request with 400. The probe accepts `[200]` or `[200; 400]`.

## Passing Coverage Kept

The family continues to cover CL/TE conflicts, duplicate Content-Length,
invalid header syntax, invalid targets, Host validation, and connection-close
smuggling.
