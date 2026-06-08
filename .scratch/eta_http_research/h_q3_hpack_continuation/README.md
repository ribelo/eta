# H-Q3 HPACK Bombs and CONTINUATION Floods

Question: do eta-http's default h2 header limits stop malicious decompression and header-block accumulation before unbounded memory growth?

Default caps proved here:

- HPACK decoded header block cap: `256 KiB`.
- CONTINUATION accumulator cap: `64 KiB`.

Fixtures:

- HPACK bomb: `10 KiB` encoded input expands to `100 MiB` decoded via dynamic-table reuse. The decoder aborts at the 256 KiB decoded cap and maps to `Hpack_decode_overflow`.
- CONTINUATION flood: 1000 frames before END_HEADERS, each 1 KiB. The accumulator aborts at frame 64 with a 64 KiB cap and maps to `Continuation_flood`.

Default justification:

- The synthetic OTel/header inventory includes W3C trace context, baggage, auth/cookie style headers, large gRPC metadata, and an OTLP resource-attribute p99 row of 64 KiB.
- The 256 KiB HPACK decoded cap is 4x that 64 KiB p99 inventory row.
- The 64 KiB CONTINUATION cap is 4x a 16 KiB large-header baseline.
