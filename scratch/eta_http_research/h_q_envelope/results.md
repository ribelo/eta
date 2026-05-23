# H-Q Envelope Results

## Status

PARTIAL against the original H-Q catalogue. 6 of 12 catalogue attacks pass against the H-D1 SUT. 6 are deferred to byte-level adapter hooks tracked in Eta-h2-raw-frame-envelope. The allocator-pressure falsifier passes against the active-path rate: the three selected active attacks stay <= 281.17 words/admitted-frame against the 2260 envelope. This is a partial v1 client-security claim; the full claim depends on the deferred set landing with the eta-http implementation epic.

Verdict: PASS for the H-D1-exercisable attack subset, PASS for the active-path allocator falsifier, and DEFERRED for byte-level attack classes that the current H-D1 scratch frame model cannot represent.

This is not a full byte-parser PASS. It is a bounded envelope for the current H-D1/H-D-Errors scratch SUT plus an explicit reopener list for the eta-http implementation epic.

## Command

    nix develop -c dune exec scratch/eta_http_research/h_q_envelope/fixtures.exe

Exit status: 0.

The CSV has 404 lines: one header plus 13 rows x 31 samples for seconds 0 through 30. monitoring.csv now includes alloc_words_per_admitted_frame_active, sampled from Gc.minor_words between attack start and breaker fire.

    sampling H-Q envelope every 1s for 30s
    ATTACK id=headers_rst_every_stream group=H-Q2 verdict=PASS coverage=H-D1 multiplexer error=stream_admission_rejected samples=31 frames=2000 dropped=872 alloc_words_per_admitted_frame_active=281.17 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=128 completed=128 remote_resets=128 rejected=872)
    ATTACK id=goaway_mid_flight group=H-Q2 verdict=DEFERRED: H-D1 Frame has no GOAWAY constructor or last_stream_id cutoff hook; covered as connection teardown only. coverage=deferred - missing capability H-D1 Frame has no GOAWAY constructor or last_stream_id cutoff hook; covered as connection teardown only. error=connection_closed samples=31 frames=1 dropped=0 alloc_words_per_admitted_frame_active=31.00 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
    ATTACK id=header_churn group=H-Q2 verdict=DEFERRED: H-D1 Frame.Headers carries only stream_id/tag/end_stream; no header block is exposed to mutate. coverage=deferred - missing capability H-D1 Frame.Headers carries only stream_id/tag/end_stream; no header block is exposed to mutate. error=response_header_change_rate_exceeded samples=31 frames=128 dropped=96 alloc_words_per_admitted_frame_active=0.24 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
    ATTACK id=stream_id_jumps group=H-Q2 verdict=PASS coverage=H-D1 multiplexer error=stream_admission_rejected samples=31 frames=10000 dropped=10000 alloc_words_per_admitted_frame_active=98.43 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
    ATTACK id=rst_rate_exceeded group=H-Q2 verdict=PASS coverage=H-D1 multiplexer error=rst_rate_exceeded samples=31 frames=250 dropped=150 alloc_words_per_admitted_frame_active=870.04 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=128 completed=128 remote_resets=128 rejected=122)
    ATTACK id=ping_flood group=H-Q5 verdict=PASS coverage=H-D1 multiplexer error=ping_rate_exceeded samples=31 frames=1000 dropped=900 alloc_words_per_admitted_frame_active=72.34 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
    ATTACK id=settings_header_table_size_churn group=H-Q5 verdict=DEFERRED: H-D1 Frame has no SETTINGS constructor; this remains an ocaml-h2 adapter parser hook. coverage=deferred - missing capability H-D1 Frame has no SETTINGS constructor; this remains an ocaml-h2 adapter parser hook. error=settings_churn_rate_exceeded samples=31 frames=250 dropped=240 alloc_words_per_admitted_frame_active=0.12 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
    ATTACK id=window_update_accounting group=H-Q5 verdict=PASS coverage=H-D1 multiplexer error=connection_protocol_violation samples=31 frames=2000 dropped=1000 alloc_words_per_admitted_frame_active=153.84 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=1 completed=1 remote_resets=0 rejected=0)
    ATTACK id=goaway_churn group=H-Q5 verdict=DEFERRED: H-D1 Frame has no GOAWAY; H-D5 can model close/reopen churn but not raw GOAWAY last_stream_id semantics. coverage=deferred - missing capability H-D1 Frame has no GOAWAY; H-D5 can model close/reopen churn but not raw GOAWAY last_stream_id semantics. error=connection_closed samples=31 frames=2 dropped=0 alloc_words_per_admitted_frame_active=15.50 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
    ATTACK id=data_frame_slowloris group=H-Q5 verdict=PASS coverage=H-D1 multiplexer error=response_body_idle_timeout samples=31 frames=8 dropped=8 alloc_words_per_admitted_frame_active=1477.25 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=1 completed=1 remote_resets=0 rejected=0)
    ATTACK id=huffman_cpu_amplification group=H-Q5 verdict=DEFERRED: H-D1 has no HPACK/Huffman decoder; H-Q3 covers decoded-size caps but not Huffman CPU cost. coverage=deferred - missing capability H-D1 has no HPACK/Huffman decoder; H-Q3 covers decoded-size caps but not Huffman CPU cost. error=hpack_decode_overflow samples=31 frames=1000 dropped=968 alloc_words_per_admitted_frame_active=0.03 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
    ATTACK id=header_normalization_edges group=H-Q5 verdict=DEFERRED: H-D1 Frame.Headers lacks header names/values; this belongs to the ocaml-h2 adapter normalization boundary. coverage=deferred - missing capability H-D1 Frame.Headers lacks header names/values; this belongs to the ocaml-h2 adapter normalization boundary. error=header_invalid samples=31 frames=64 dropped=32 alloc_words_per_admitted_frame_active=0.48 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=0 completed=0 remote_resets=0 rejected=0)
    ATTACK id=allocator_pressure group=H-Q5-alloc verdict=PASS coverage=adapter policy only error=connection_protocol_violation samples=31 frames=14000 dropped=11872 alloc_words_per_admitted_frame_active=132.40 alloc_words_per_frame_after_warmup=0.00 streams(active=0 cancelled=0 live=0 opened=129 completed=129 remote_resets=128 rejected=872)

## Per-Attack Verdicts

| Attack | Verdict | Coverage | Typed error | Notes |
| --- | --- | --- | --- | --- |
| HEADERS + RST_STREAM after every stream | PASS | H-D1 multiplexer | Stream_admission_rejected | 1000 attempts, 128 opened, 872 rejected, stream state baseline restored. |
| GOAWAY mid-flight | DEFERRED | Missing H-D1 GOAWAY frame | Connection_closed | Current H-D1 can model teardown, not GOAWAY last_stream_id semantics. |
| Header churn | DEFERRED | Missing header block representation | Response_header_change_rate_exceeded | H-D1 headers contain no names/values to churn. |
| Stream-id jumps | PASS | H-D1 multiplexer | Stream_admission_rejected | 10,000 unknown stream frames dropped with no stream state allocation. |
| RST_STREAM rate exceeded | PASS | H-D1 multiplexer | Rst_rate_exceeded | 250 attempts, breaker threshold 100/sec, baseline restored. |
| PING flood | PASS | H-D1 multiplexer | Ping_rate_exceeded | 1000 PING frames, 900 above default policy, no stream state allocation. |
| SETTINGS_HEADER_TABLE_SIZE churn | DEFERRED | Missing SETTINGS frame | Settings_churn_rate_exceeded | Requires ocaml-h2 adapter parser hook. |
| WINDOW_UPDATE accounting attacks | PASS | H-D1 multiplexer | Connection_protocol_violation | 2000 updates, stalled stream released, baseline restored. |
| GOAWAY churn | DEFERRED | Missing GOAWAY frame | Connection_closed | H-D5 close/reopen churn can be modeled later, but raw GOAWAY is absent. |
| DATA-frame slowloris | PASS | H-D1 multiplexer | Response_body_idle_timeout | Trickled DATA never completes response; timeout releases stream. |
| Huffman CPU amplification | DEFERRED | Missing HPACK/Huffman decoder | Hpack_decode_overflow | H-Q3 covers decoded-size cap, not Huffman CPU cost. |
| Header normalization edge cases | DEFERRED | Missing header names/values | Header_invalid | Requires adapter normalization boundary. |
| Allocator-pressure falsifier | PASS | Active-path metric over selected attacks | Connection_protocol_violation | Selected active rates stay <= 281.17 words/admitted-frame; aggregate allocator row measured 132.40. |

## Allocator Active-Path Falsifier

Hypothesis: H-D1's active processing path stays below 2x the H-D1 benign baseline of 1129.6 minor words/stream. Envelope: fail above 2260 words/admitted-frame.

| Attack | Active rate | Verdict |
| --- | ---: | --- |
| HEADERS + RST_STREAM after every stream | 281.17 words/frame | PASS |
| WINDOW_UPDATE accounting attacks | 153.84 words/frame | PASS |
| Stream-id jumps | 98.43 words/frame | PASS |

The old post-disconnect metric remains a secondary observation only. It measured 0.00 words/frame after warm-up because the SUT had already disconnected.

## Resource Envelope

Observed from monitoring.csv:

- RSS plateaued at 36996 KiB in the tail samples.
- fd count stayed at 4.
- modeled fiber count stayed at 0 after disconnect.
- stream active/cancelled/live counts returned to 0 for every row.
- active-path allocator pressure stayed below the 2260 words/frame envelope for the selected falsifier rows.

## Deferred Rows

These are not silent skips:

| Attack | Missing capability |
| --- | --- |
| GOAWAY mid-flight | H-D1 Frame.Goaway with last_stream_id and adapter admission cutoff. |
| Header churn | Header block names/values in the SUT. |
| SETTINGS_HEADER_TABLE_SIZE churn | H-D1 or adapter SETTINGS frame hook. |
| GOAWAY churn | Raw GOAWAY plus H-D5 close/reopen loop accounting. |
| Huffman CPU amplification | HPACK/Huffman decoder CPU measurement hook. |
| Header normalization edge cases | Adapter header normalization boundary. |

## Residual Risk

The current result is enough to keep eta-http implementation planning honest: the existing H-D1 multiplexer paths are bounded under the exercisable attacks, but eta-http v1 still needs byte-level adapter fixtures before claiming full malicious-server HTTP/2 coverage.
