# H-Q3 Defaults Justification

Measured inventory used by the scratch lab:

| Header source | Bytes |
| --- | ---: |
| traceparent | 55 |
| tracestate | 256 |
| baggage | 4096 |
| authorization | 8192 |
| cookie | 16384 |
| set-cookie | 16384 |
| grpc metadata large | 32768 |
| otlp resource attrs synthetic p99 | 65536 |

Defaults:

- Decoded HPACK cap: `256 KiB`, equal to 4x the 64 KiB p99 inventory row.
- CONTINUATION accumulator cap: `64 KiB`, equal to 4x a 16 KiB large-header baseline.

Rationale:

- A 256 KiB decoded cap is large enough for unusual but plausible telemetry metadata while stopping 100 MiB dynamic-table amplification.
- A 64 KiB CONTINUATION accumulator stops a 1000-frame header flood at frame 64 for 1 KiB frames.
- A user may raise the decoded HPACK cap to 1 MiB; the fixture verifies the 100 MiB bomb still aborts at that elevated cap.
