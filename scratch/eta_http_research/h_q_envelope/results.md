# H-Q Envelope Results

Verdict: PASS for the H-D1-exercisable attack subset, PASS for the
adapter-policy allocator falsifier, and DEFERRED for byte-level attack classes
that the current H-D1 scratch frame model cannot represent.

This is not a full byte-parser PASS. It is a bounded envelope for the current
H-D1/H-D-Errors scratch SUT plus an explicit reopener list for the eta-http
implementation epic.

## Command

```sh
nix develop -c dune exec scratch/eta_http_research/h_q_envelope/fixtures.exe
```

Exit status: `0`.

The PTY run was used so the command could finish after the 30-second sampling
window. The raw CSV has 404 lines: one header plus 13 attacks x 31 samples
for seconds 0 through 30.

```text
sampling H-Q envelope every 1s for 30s
ATTACK id=headers_rst_every_stream group=H-Q2 verdict=PASS coverage=H-D1 multiplexer error=stream_admission_rejected samples=31 frames=2000 dropped=872 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=128 completed=128 remote_resets=128 rejected=872)
ATTACK id=goaway_mid_flight group=H-Q2 verdict=DEFERRED: H-D1 Frame has no GOAWAY constructor or last_stream_id cutoff hook; covered as connection teardown only. coverage=deferred - missing capability H-D1 Frame has no GOAWAY constructor or last_stream_id cutoff hook; covered as connection teardown only. error=connection_closed samples=31 frames=1 dropped=0 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
ATTACK id=header_churn group=H-Q2 verdict=DEFERRED: H-D1 Frame.Headers carries only stream_id/tag/end_stream; no header block is exposed to mutate. coverage=deferred - missing capability H-D1 Frame.Headers carries only stream_id/tag/end_stream; no header block is exposed to mutate. error=decode_error samples=31 frames=128 dropped=96 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
ATTACK id=stream_id_jumps group=H-Q2 verdict=PASS coverage=H-D1 multiplexer error=stream_admission_rejected samples=31 frames=10000 dropped=10000 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
ATTACK id=rst_rate_exceeded group=H-Q2 verdict=PASS coverage=H-D1 multiplexer error=rst_rate_exceeded samples=31 frames=250 dropped=150 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=128 completed=128 remote_resets=128 rejected=122)
ATTACK id=ping_flood group=H-Q5 verdict=PASS coverage=H-D1 multiplexer error=connection_closed samples=31 frames=1000 dropped=900 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
ATTACK id=settings_header_table_size_churn group=H-Q5 verdict=DEFERRED: H-D1 Frame has no SETTINGS constructor; this remains an ocaml-h2 adapter parser hook. coverage=deferred - missing capability H-D1 Frame has no SETTINGS constructor; this remains an ocaml-h2 adapter parser hook. error=decode_error samples=31 frames=250 dropped=240 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
ATTACK id=window_update_accounting group=H-Q5 verdict=PASS coverage=H-D1 multiplexer error=decode_error samples=31 frames=2000 dropped=1000 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=1 completed=1 remote_resets=0 rejected=0)
ATTACK id=goaway_churn group=H-Q5 verdict=DEFERRED: H-D1 Frame has no GOAWAY; H-D5 can model close/reopen churn but not raw GOAWAY last_stream_id semantics. coverage=deferred - missing capability H-D1 Frame has no GOAWAY; H-D5 can model close/reopen churn but not raw GOAWAY last_stream_id semantics. error=connection_closed samples=31 frames=2 dropped=0 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
ATTACK id=data_frame_slowloris group=H-Q5 verdict=PASS coverage=H-D1 multiplexer error=response_body_idle_timeout samples=31 frames=8 dropped=8 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=1 completed=1 remote_resets=0 rejected=0)
ATTACK id=huffman_cpu_amplification group=H-Q5 verdict=DEFERRED: H-D1 has no HPACK/Huffman decoder; H-Q3 covers decoded-size caps but not Huffman CPU cost. coverage=deferred - missing capability H-D1 has no HPACK/Huffman decoder; H-Q3 covers decoded-size caps but not Huffman CPU cost. error=hpack_decode_overflow samples=31 frames=1000 dropped=968 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
ATTACK id=header_normalization_edges group=H-Q5 verdict=DEFERRED: H-D1 Frame.Headers lacks header names/values; this belongs to the ocaml-h2 adapter normalization boundary. coverage=deferred - missing capability H-D1 Frame.Headers lacks header names/values; this belongs to the ocaml-h2 adapter normalization boundary. error=decode_error samples=31 frames=64 dropped=32 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
ATTACK id=allocator_pressure group=H-Q5-alloc verdict=PASS coverage=adapter policy only error=decode_error samples=31 frames=1000 dropped=0 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
```

## Per-Attack Verdicts

| Attack | Verdict | Coverage | Typed error | Notes |
| --- | --- | --- | --- | --- |
| HEADERS + RST_STREAM after every stream | PASS | H-D1 multiplexer | `Stream_admission_rejected` | 1000 attempts, 128 opened, 872 rejected, stream state baseline restored. |
| GOAWAY mid-flight | DEFERRED | Missing H-D1 GOAWAY frame | `Connection_closed` | Current H-D1 can model teardown, not GOAWAY `last_stream_id` semantics. |
| Header churn | DEFERRED | Missing header block representation | `Decode_error` | H-D1 headers contain no names/values to churn. |
| Stream-id jumps | PASS | H-D1 multiplexer | `Stream_admission_rejected` | 10,000 unknown stream frames dropped with no stream state allocation. |
| RST_STREAM rate exceeded | PASS | H-D1 multiplexer | `Rst_rate_exceeded` | 250 attempts, breaker threshold 100/sec, baseline restored. |
| PING flood | PASS | H-D1 multiplexer | `Connection_closed` | 1000 PING frames, 900 above default policy, no stream state allocation. |
| SETTINGS_HEADER_TABLE_SIZE churn | DEFERRED | Missing SETTINGS frame | `Decode_error` | Requires ocaml-h2 adapter parser hook. |
| WINDOW_UPDATE accounting attacks | PASS | H-D1 multiplexer | `Decode_error` | 2000 updates, stalled stream released, baseline restored. |
| GOAWAY churn | DEFERRED | Missing GOAWAY frame | `Connection_closed` | H-D5 close/reopen churn can be modeled later, but raw GOAWAY is absent. |
| DATA-frame slowloris | PASS | H-D1 multiplexer | `Response_body_idle_timeout` | Trickled DATA never completes response; timeout releases stream. |
| Huffman CPU amplification | DEFERRED | Missing HPACK/Huffman decoder | `Hpack_decode_overflow` | H-Q3 covers decoded-size cap, not Huffman CPU cost. |
| Header normalization edge cases | DEFERRED | Missing header names/values | `Decode_error` | Requires adapter normalization boundary. |
| Allocator-pressure falsifier | PASS | Adapter policy model | `Decode_error` | Header, SETTINGS, and WINDOW_UPDATE candidates show `0.00` post-warmup words/frame after disconnect. |

## Resource Envelope

Observed from `monitoring.csv`:

- RSS plateaued at `38624 KiB` in the tail samples.
- fd count stayed at `4`.
- modeled fiber count stayed at `0` after disconnect.
- stream active/cancelled/live counts returned to `0` for every row.
- post-warmup allocator pressure was `0.00` words per attack frame for every row.

The initial allocation delta is the cost of preparing the SUT and attack
catalogue. It does not grow after the warm-up window because the policy is
drop-and-disconnect.

## Deferred Rows

These are not silent skips:

| Attack | Missing capability |
| --- | --- |
| GOAWAY mid-flight | H-D1 `Frame.Goaway` with `last_stream_id` and adapter admission cutoff. |
| Header churn | Header block names/values in the SUT. |
| SETTINGS_HEADER_TABLE_SIZE churn | H-D1 or adapter SETTINGS frame hook. |
| GOAWAY churn | Raw GOAWAY plus H-D5 close/reopen loop accounting. |
| Huffman CPU amplification | HPACK/Huffman decoder CPU measurement hook. |
| Header normalization edge cases | Adapter header normalization boundary. |

## Residual Risk

The current result is enough to keep eta-http implementation planning honest:
the existing H-D1 multiplexer paths are bounded under the exercisable attacks,
but eta-http v1 still needs byte-level adapter fixtures before claiming full
malicious-server HTTP/2 coverage.
