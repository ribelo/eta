# R2 h1 Request Writer Probe

Hypothesis: eta-http can serialize HTTP/1.1 requests from the public request
shape without adding a writer dependency.

Scope:

- origin-form request target derived from `Eta_http.Core.Url`;
- automatic `Host`;
- automatic `Connection: keep-alive`;
- fixed body `Content-Length`;
- caller headers preserved;
- direct transport writing without building one complete request string.

Disproof signature from `OBJECTIVE.md`: the zero-allocation shape cannot be
maintained, unboxed state cannot represent the writer, or the public API forces
heap allocation at the consumer boundary.

Verdict: PASS for the S1 writer core.

Evidence:

```sh
nix develop -c dune runtest lib/http --force
bash lib/http/audit/run.sh
nix develop -c dune exec scratch/eta_http_v1/probes/writer_alloc.exe
```

Observed:

```text
eta-http: 26 tests passed
Dependency sites: 70
Eta escape sites: 0
eta_http_r2_writer_alloc verdict=PASS iterations=100000 minor_words=0 words_per_write=0.000000 checksum=15600000
```

The implemented writer still supports `to_string` for tests and fixtures. The
transport path now calls `Eta_http_h1.Write.write_to_flow`, which writes
request fragments directly to an Eio flow sink instead of allocating one
complete request string. The `flow matches string writer` test proves the
direct writer stays byte-identical to the existing wire-format fixtures.

The zero-allocation subject is `Eta_http_h1.Write.write_to_bytes_raw`, a
caller-owned byte-buffer writer. It is annotated with `[@zero_alloc]`; the
package build checks that annotation, and `writer_alloc.exe` measures 0 minor
words over 100,000 steady-state writes.

Residual risk:

- `write_to_flow` crosses the Eio sink boundary and is not the zero-allocation
  subject. The S1 claim is the clean-room writer core plus no complete request
  string allocation on the transport path.
