# H-Q3 Results

Verdict: PASS.

```text
nix develop -c bash -lc 'dune build scratch/eta_http_research/h_q3_hpack_continuation/fixtures.exe && dune exec scratch/eta_http_research/h_q3_hpack_continuation/fixtures.exe'
HPACK encoded=10240 decoded=104857600 limit=262144
PASS HPACK bomb shape is 10KB to 100MB
PASS HPACK decoded cap aborts at 256KB
PASS HPACK user-elevated 1MB cap still aborts
CONTINUATION frames=1000 frame_bytes=1024 abort_frame=64 accumulated=65536 limit=65536
PASS CONTINUATION flood has 1000 1KB frames
PASS CONTINUATION accumulator aborts around frame 64
PASS CONTINUATION flood maps typed error
PASS decoded cap is 4x p99 inventory
PASS continuation cap is 4x large-header baseline
h_q3_hpack_continuation fixtures passed
```

Typed error mapping:

- HPACK decoded overflow -> `Hpack_decode_overflow { decoded_bytes = 104857600; limit_bytes = 262144 }`.
- CONTINUATION flood -> `Continuation_flood { accumulated_bytes = 65536; limit_bytes = 65536; frames = 64 }`.

Decision:

- Accept `256 KiB` as the default decoded HPACK cap.
- Accept `64 KiB` as the default CONTINUATION accumulator cap.
- Keep both caps configurable in eta-http implementation work.
