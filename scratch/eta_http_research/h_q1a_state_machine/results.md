# H-Q1a Results

Verdict: PASS.

The eta-http adapter/state-machine invariants can be expressed as seeded property tests over the H-D1 stream state and a small adapter model. This tests eta-http lifecycle behavior directly rather than ocaml-h2 frame parsing.

```text
nix develop -c dune exec scratch/eta_http_research/h_q1a_state_machine/fixtures.exe
PROPERTY property_a_permits_return_to_baseline seed=47001 trials=300
COVERAGE sequences_with_cancel_or_rst=300
SHRINK none
PASS property_a_permits_return_to_baseline coverage sequences_with_cancel_or_rst
PROPERTY property_b_no_body_after_rst seed=47002 trials=300
COVERAGE rst_and_data_sequences=300
SHRINK none
PASS property_b_no_body_after_rst coverage rst_and_data_sequences
PROPERTY property_c_window_never_negative seed=47003 trials=300
COVERAGE multi_data_sequences=137
SHRINK none
PASS property_c_window_never_negative coverage multi_data_sequences
PROPERTY property_d_trailers_after_end_stream seed=47004 trials=300
COVERAGE sequences_with_trailers=300
SHRINK none
PASS property_d_trailers_after_end_stream coverage sequences_with_trailers
PROPERTY property_e_goaway_blocks_new_streams seed=47005 trials=300
COVERAGE sequences_with_goaway=300
SHRINK none
PASS property_e_goaway_blocks_new_streams coverage sequences_with_goaway
PROPERTY property_f_body_exhausted_once seed=47006 trials=300
COVERAGE multi_read_sequences=300
SHRINK none
PASS property_f_body_exhausted_once coverage multi_read_sequences
PROPERTY property_g_retry_classifier_matches_h_d_errors seed=47007 trials=300
COVERAGE retryable_outcomes=178
SHRINK none
PASS property_g_retry_classifier_matches_h_d_errors coverage retryable_outcomes
PROPERTY property_h_pool_arithmetic seed=47008 trials=300
COVERAGE open_release_sequences=300
SHRINK none
PASS property_h_pool_arithmetic coverage open_release_sequences
PROPERTY property_i_server_push_rejected seed=47009 trials=120
COVERAGE push_promise_sequences=120
SHRINK none
PASS property_i_server_push_rejected coverage push_promise_sequences
PROPERTY property_j_priority_accepted_ignored seed=47010 trials=120
COVERAGE priority_sequences=120
SHRINK none
PASS property_j_priority_accepted_ignored coverage priority_sequences
h_q1a_state_machine properties passed
```

Decisions:

- Keep state-machine properties at the eta-http adapter level. The generator produces operations such as request, cancel, body-read, RST_STREAM, GOAWAY, PUSH_PROMISE, PRIORITY, trailer, and release.
- Reuse H-D1 `Stream_state` for the real active/cancelled/live counters and release behavior.
- Model GOAWAY, server push, priority, trailers, pool arithmetic, and retry-classification at the adapter boundary where eta-http owns the behavior.
- Cite RFC 9113 section 8.4 in the server-push property and RFC 9113 section 5.3.2 in the PRIORITY property.

Residual risk:

- This is not byte-level frame parsing. H-Q2/H-Q3 malicious peer fixtures still need to exercise the multiplexer and memory/fiber counters under hostile frame streams.
