# R1 h1 Response Parser Probe

Hypothesis: a clean-room client-side HTTP/1.x response parser can keep parsed
fields as spans into a caller-owned buffer and avoid string copies on the parse
path.

Scope:

- status line for `HTTP/1.0` and `HTTP/1.1`;
- response status code and reason phrase;
- header section with token names and OWS-trimmed values;
- duplicate `Content-Length` rejection when values disagree;
- fixed body span based on `Content-Length`, or remaining bytes when absent;
- raw parser core that writes into caller-owned state and returns integer
  status codes;
- h1 client response read loop using a 32 KiB preallocated parser buffer.

Disproof signature from `OBJECTIVE.md`: the parser cannot maintain the
zero-copy shape, OxCaml parser state cannot represent the shape, or the API
forces allocation at the consumer boundary.

Verdict: PASS for the S1 parser core and h1 client read loop.

Evidence:

```sh
nix develop -c dune runtest packages/eta-http --force
nix develop -c dune exec scratch/eta_http_v1/probes/parser_alloc.exe
```

Observed:

```text
eta-http: 28 tests passed
eta_http_r1_parser_alloc verdict=PASS iterations=100000 minor_words=0 words_per_parse=0.000000 checksum=28150000
```

The parser returns spans into `bytes` for reason, headers, and body. Accessors
such as `span_to_string`, `headers_to_list`, and `body_to_bytes` allocate
deliberately at consumer boundaries.

`Http.H1.Parse.parse_raw` is the measured core: it fills caller-owned
header arrays and a caller-owned response record, is annotated with
`[@zero_alloc]`, and is used by the h1 client response loop. The client reads
transport bytes through Eio's `Cstruct.t` boundary into a fixed 32 KiB parser
buffer before parsing.

Residual risk:

- Public `parse` and accessor helpers allocate public records, lists, strings,
  and bytes by design. The S1 zero-allocation claim is limited to
  `parse_raw`.
- The implementation uses ordinary `int` offsets in caller-owned arrays rather
  than `int16#` spans. Current OxCaml evidence shows this still satisfies the
  zero-allocation S1 gate.
- The Eio `Cstruct.t` read boundary is outside the parser-core measurement.
