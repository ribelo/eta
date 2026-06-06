open Test_eta_http_core
open Test_eta_http_body
open Test_eta_http_url
open Test_eta_http_h1_write
open Test_eta_http_h1_parse
open Test_eta_http_transport
open Test_eta_http_h1_client
open Test_eta_http_ws
open Test_eta_http_retry
open Test_eta_http_observability
open Test_eta_http_tls
open Test_eta_http_h2_state
open Test_eta_http_h2_writer
open Test_eta_http_h2_connection
open Test_eta_http_h2_multiplexer
open Test_eta_http_h2_security
open Test_eta_http_alpn_dispatch

let () =
  Alcotest.run "eta-http"
    [
      ("skeleton", [ Alcotest.test_case "loads" `Quick test_skeleton_loads ]);
      ( "header",
        [
          Alcotest.test_case "value accepts HTAB" `Quick
            test_header_value_accepts_htab;
          Alcotest.test_case "method parsing preserves semantics" `Quick
            test_method_of_string_fast_path_semantics;
          Alcotest.test_case "trace context request helpers" `Quick
            test_trace_context_request_helpers;
        ] );
      ( "error",
        [
          Alcotest.test_case "redaction and projection" `Quick
            test_error_redaction_and_projection;
        ] );
      ( "body",
        [
          Alcotest.test_case "release once" `Quick test_body_stream_release_once;
          Alcotest.test_case "reader release once" `Quick
            test_body_stream_reader_release_once;
          Alcotest.test_case "rejects concurrent reads" `Quick
            test_body_stream_rejects_concurrent_reads;
          Alcotest.test_case "source owned stream release" `Quick
            test_body_source_owned_stream_releases_on_scope_exit;
          Alcotest.test_case "source rewindable stream ownership" `Quick
            test_body_source_rewindable_stream_is_owned_per_call;
          Alcotest.test_case "read_all caps default" `Quick
            test_body_stream_read_all_caps_default;
          Alcotest.test_case "chunked trailers" `Quick
            test_chunked_decodes_trailers;
          Alcotest.test_case "chunked rejects invalid trailer header" `Quick
            test_chunked_decoder_rejects_invalid_trailer_header;
          Alcotest.test_case "chunked encoder" `Quick test_chunked_encoder;
          Alcotest.test_case "chunked encoder rejects invalid trailers" `Quick
            test_chunked_encoder_rejects_invalid_trailers;
          Alcotest.test_case "gzip roundtrip" `Quick
            test_gzip_transducer_roundtrip;
          Alcotest.test_case "gzip expansion cap" `Quick
            test_gzip_transducer_expansion_cap;
          Alcotest.test_case "gzip truncated stream" `Quick
            test_gzip_transducer_rejects_truncated_stream;
          Alcotest.test_case "gzip CRC mismatch" `Quick
            test_gzip_transducer_rejects_crc_mismatch;
          Alcotest.test_case "gzip concatenated members" `Quick
            test_gzip_transducer_decodes_concatenated_members;
        ] );
      ( "client",
        [
          Alcotest.test_case "make_h1 request path" `Quick
            test_client_make_h1_request_path;
          Alcotest.test_case "rejects cross-domain use" `Quick
            test_client_rejects_cross_domain_use;
        ] );
      ( "retry",
        [
          Alcotest.test_case "idempotency classifier" `Quick
            test_idempotency_classifier;
          Alcotest.test_case "Retry-After parser" `Quick
            test_retry_after_parser;
          Alcotest.test_case "Retry-After absolute date uses clock" `Quick
            test_retry_after_absolute_date_uses_clock;
          Alcotest.test_case "schedule backoff" `Quick
            test_retry_policy_schedule_backoff;
          Alcotest.test_case "rejects invalid max_attempts" `Quick
            test_retry_policy_rejects_invalid_max_attempts;
          Alcotest.test_case "max_attempts one does not retry" `Quick
            test_retry_policy_max_attempts_one_does_not_retry;
          Alcotest.test_case "connection closed uses generic retry" `Quick
            test_retry_policy_connection_closed_is_generic_retry;
          Alcotest.test_case "custom status classifier" `Quick
            test_retry_policy_custom_status_classifier;
          Alcotest.test_case "succeeds on third attempt" `Quick
            test_retry_succeeds_on_third_attempt;
          Alcotest.test_case "non-idempotent requires opt-in" `Quick
            test_retry_non_idempotent_requires_opt_in;
          Alcotest.test_case "always requires replayable body" `Quick
            test_retry_always_still_requires_replayable_body;
        ] );
      ( "observability",
        [
          Alcotest.test_case "successful GET semconv" `Quick
            test_observability_success_get_semconv;
          Alcotest.test_case "redacts URL query by default" `Quick
            test_observability_redacts_url_query_by_default;
          Alcotest.test_case "can emit raw url.full" `Quick
            test_observability_can_emit_raw_url_full;
          Alcotest.test_case "DNS error semconv" `Quick
            test_observability_dns_error_semconv;
          Alcotest.test_case "TLS error semconv" `Quick
            test_observability_tls_error_semconv;
          Alcotest.test_case "retry success spans" `Quick
            test_observability_retry_success_spans;
          Alcotest.test_case "redirect semconv" `Quick
            test_observability_redirect_semconv;
          Alcotest.test_case "redirect semconv raw opt-in" `Quick
            test_observability_redirect_semconv_can_emit_raw;
          Alcotest.test_case "h2 protocol attrs" `Quick
            test_observability_h2_protocol_attrs;
          Alcotest.test_case "recursion disabled" `Quick
            test_observability_recursion_disabled;
          Alcotest.test_case "recursion disabled suppresses inner spans" `Quick
            test_observability_recursion_disabled_suppresses_inner_spans;
          Alcotest.test_case "pool stats meter" `Quick
            test_observability_pool_stats_meter;
        ] );
      ( "url",
        [
          Alcotest.test_case "client subset" `Quick test_url_parse_client_subset;
          Alcotest.test_case "fragment question mark is not query" `Quick
            test_url_fragment_question_mark_not_query;
          Alcotest.test_case "IPv6 authority brackets" `Quick
            test_url_ipv6_authority_restores_brackets;
          Alcotest.test_case "reject unsupported forms" `Quick
            test_url_rejects_unsupported_forms;
        ] );
      ( "h1-write",
        [
          Alcotest.test_case "GET origin-form" `Quick
            test_h1_writer_get_origin_form;
          Alcotest.test_case "fixed body" `Quick test_h1_writer_fixed_body;
          Alcotest.test_case "rejects mismatched Content-Length" `Quick
            test_h1_writer_rejects_mismatched_content_length;
          Alcotest.test_case "rejects invalid Content-Length framing" `Quick
            test_h1_writer_rejects_invalid_content_length_framing;
          Alcotest.test_case "rejects Transfer-Encoding fixed body" `Quick
            test_h1_writer_rejects_transfer_encoding_for_fixed_body;
          Alcotest.test_case "stream override does not reframe fixed body" `Quick
            test_h1_writer_stream_override_does_not_reframe_fixed_body;
          Alcotest.test_case "flow matches string writer" `Quick
            test_h1_writer_flow_matches_string_writer;
          Alcotest.test_case "flow write failure is typed" `Quick
            test_h1_writer_flow_write_failure_is_typed;
          Alcotest.test_case "flow write cancellation propagates" `Quick
            test_h1_writer_flow_write_cancellation_propagates;
          Alcotest.test_case "bytes matches string writer" `Quick
            test_h1_writer_bytes_matches_string_writer;
          Alcotest.test_case "bytes rejects small buffer" `Quick
            test_h1_writer_bytes_rejects_small_buffer;
          Alcotest.test_case "rejects header injection" `Quick
            test_h1_writer_rejects_header_injection;
        ] );
      ( "h1-parse",
        [
          Alcotest.test_case "fixed body" `Quick test_h1_parser_fixed_body;
          Alcotest.test_case "no body response" `Quick test_h1_parser_no_body_head;
          Alcotest.test_case "bad content length" `Quick
            test_h1_parser_rejects_bad_content_length;
          Alcotest.test_case "conflicting content length" `Quick
            test_h1_parser_rejects_conflicting_content_length;
          Alcotest.test_case "invalid header value controls" `Quick
            test_h1_parser_rejects_invalid_header_value_controls;
        ] );
      ( "h1-client",
        [
          Alcotest.test_case "request on flow fixed response" `Quick
            test_h1_client_request_on_flow_fixed_response;
          Alcotest.test_case "split response" `Quick
            test_h1_client_reads_split_response;
          Alcotest.test_case "decodes chunked response" `Quick
            test_h1_client_decodes_chunked_response;
          Alcotest.test_case "caps close-delimited body" `Quick
            test_h1_client_caps_close_delimited_body;
          Alcotest.test_case "streaming request body releases" `Quick
            test_h1_client_streaming_request_body_releases;
          Alcotest.test_case "stream cancel releases request body" `Quick
            test_h1_client_cancelled_streaming_request_body_releases;
          Alcotest.test_case "stream write failure releases request body" `Quick
            test_h1_client_streaming_request_body_releases_on_write_failure;
          Alcotest.test_case "stream write cancellation remains cancellation" `Quick
            test_h1_client_streaming_request_body_write_cancellation_propagates;
          Alcotest.test_case "rejects mismatched stream Content-Length" `Quick
            test_h1_client_rejects_mismatched_stream_content_length;
          Alcotest.test_case "custom release on write failure" `Quick
            test_h1_client_custom_release_on_write_failure;
          Alcotest.test_case "custom release on response header failure" `Quick
            test_h1_client_custom_release_on_response_header_failure;
          Alcotest.test_case "HEAD ignores chunked body headers" `Quick
            test_h1_client_head_ignores_chunked_body_headers;
          Alcotest.test_case "skips 100 Continue" `Quick
            test_h1_client_skips_100_continue;
          Alcotest.test_case "origin pool creation is fenced" `Quick
            test_h1_client_origin_pool_creation_is_fenced;
          Alcotest.test_case "pool reuses healthy idle connection" `Quick
            test_h1_pool_reuses_healthy_idle_connection;
          Alcotest.test_case "pool rejects overread bytes before reuse" `Quick
            test_h1_pool_rejects_overread_bytes_before_reuse;
          Alcotest.test_case "pool rejects unhealthy idle connection" `Quick
            test_h1_pool_rejects_unhealthy_idle_connection;
          Alcotest.test_case "pool holds checkout until body EOF" `Quick
            test_h1_pool_holds_checkout_until_body_eof;
          Alcotest.test_case "pool discard releases checkout" `Quick
            test_h1_pool_discard_releases_checkout;
          Alcotest.test_case "pool discard prevents response poisoning" `Quick
            test_h1_pool_discarded_body_does_not_poison_next_response;
          Alcotest.test_case
            "pool oversized fixed body prevents response poisoning" `Quick
            test_h1_pool_oversized_fixed_body_does_not_poison_next_response;
          Alcotest.test_case "pool cancellation releases checkout" `Quick
            test_h1_pool_request_cancellation_releases_checkout;
          Alcotest.test_case "pool marks undelivered response unreusable" `Quick
            test_h1_pool_marks_undelivered_response_unreusable;
          Alcotest.test_case "pool connection close opens new connection" `Quick
            test_h1_pool_connection_close_opens_new_connection;
          Alcotest.test_case "read exception leaks release" `Quick
            test_body_stream_read_exception_leaks_release;
        ] );
      ( "ws",
        [
          Alcotest.test_case "accept key vector" `Quick test_ws_accept_key_vector;
          Alcotest.test_case "masked text roundtrip" `Quick
            test_ws_codec_masked_text_roundtrip;
          Alcotest.test_case "random material avoids Stdlib.Random" `Quick
            test_ws_random_material_does_not_use_stdlib_random;
          Alcotest.test_case "accept key does not own SHA-1" `Quick
            test_ws_accept_key_does_not_own_sha1;
          Alcotest.test_case "upgrade reads inbound text" `Quick
            test_ws_connect_reads_inbound_text;
          Alcotest.test_case "oversized frame rejected before payload read" `Quick
            test_ws_rejects_oversized_frame_before_payload_read;
          Alcotest.test_case "send text masks client frame" `Quick
            test_ws_send_text_masks_client_frame;
          Alcotest.test_case "queued send observes close" `Quick
            test_ws_queued_send_observes_close_sent;
          Alcotest.test_case "close sent is atomic" `Quick
            test_ws_close_sent_uses_atomic_state;
          Alcotest.test_case "ping is internal and sends pong" `Quick
            test_ws_ping_is_internal_and_pong_is_sent;
          Alcotest.test_case "1011 close fails inbound stream" `Quick
            test_ws_close_1011_fails_inbound_stream;
          Alcotest.test_case "selected subprotocol" `Quick
            test_ws_selected_subprotocol;
          Alcotest.test_case "fragmented text reassembles" `Quick
            test_ws_fragmented_text_reassembles;
          Alcotest.test_case "clean close ends inbound" `Quick
            test_ws_clean_close_ends_inbound_stream;
          Alcotest.test_case "masked server frame fails" `Quick
            test_ws_server_masked_frame_is_protocol_error;
          Alcotest.test_case "real tcp echo" `Quick test_ws_connect_real_tcp_echo;
        ] );
      ( "transport",
        [
          Alcotest.test_case "resolve stream success" `Quick
            test_transport_resolve_stream_success;
          Alcotest.test_case "resolve stream empty typed" `Quick
            test_transport_resolve_stream_empty_is_typed;
          Alcotest.test_case "resolve stream cancellation propagates" `Quick
            test_transport_resolve_stream_cancellation_propagates;
          Alcotest.test_case "connect tcp success" `Quick
            test_transport_connect_tcp_success;
          Alcotest.test_case "connect tcp failure typed" `Quick
            test_transport_connect_tcp_failure_is_typed;
          Alcotest.test_case "connect tcp cancellation propagates" `Quick
            test_transport_connect_tcp_cancellation_propagates;
          Alcotest.test_case "connect tcp timeout omits connect error" `Quick
            test_transport_connect_tcp_timeout_cancels_without_connect_error;
          Alcotest.test_case "connect tls closes flow on failure" `Quick
            test_transport_connect_tls_closes_flow_on_failure;
          Alcotest.test_case "unsupported ALPN closes TLS flow" `Quick
            test_transport_dispatch_unsupported_alpn_closes_flow;
          Alcotest.test_case "supported ALPN keeps TLS flow open" `Quick
            test_transport_dispatch_supported_alpn_keeps_flow_open;
        ] );
      ( "alpn",
        [
          Alcotest.test_case "auto client uses dispatch state" `Quick
            test_auto_client_uses_alpn_dispatch_state;
          Alcotest.test_case "pending first-arrivals collapse" `Quick
            test_alpn_state_collapses_pending_first_arrivals;
          Alcotest.test_case "stale resolution and decode" `Quick
            test_alpn_state_ignores_stale_resolution_and_decodes_protocols;
        ] );
      ( "dispatch",
        [
          Alcotest.test_case "ALPN route decision" `Quick
            test_dispatch_decides_alpn_route;
        ] );
      ( "tls",
        [
          Alcotest.test_case "chokepoint policy" `Quick
            test_tls_chokepoint_policy;
          Alcotest.test_case "OpenSSL SSL finalizer ownership" `Quick
            test_openssl_ssl_finalizer_keeps_ctx_ownership_separate;
          Alcotest.test_case "handshake enters SSL mutex" `Quick
            test_tls_handshake_enters_ssl_mutex_before_openssl;
          Alcotest.test_case "client uses IP peer identity" `Quick
            test_tls_client_of_flow_uses_ip_identity;
        ] );
      ( "h2-admission",
        [
          Alcotest.test_case "cancelled counts until release" `Quick
            test_h2_admission_counts_cancelled_until_release;
        ] );
      ( "h2-frame",
        [
          Alcotest.test_case "parse header" `Quick test_h2_frame_parse_header;
        ] );
      ( "h2-stream-state",
        [
          Alcotest.test_case "release decisions" `Quick
            test_h2_stream_state_release_decisions;
          Alcotest.test_case "close releases live state" `Quick
            test_h2_stream_state_close_releases_live_state;
        ] );
      ( "h2-writer",
        [
          Alcotest.test_case "preserves iovec slices" `Quick
            test_h2_writer_preserves_iovec_slices;
          Alcotest.test_case "drains client preface and request" `Quick
            test_h2_writer_drains_client_preface_and_request;
          Alcotest.test_case "blocked write teardown" `Quick
            test_h2_writer_blocked_write_teardown;
        ] );
      ( "h2-connection",
        [
          Alcotest.test_case "concurrent streams share owner" `Quick
            test_h2_connection_concurrent_streams;
          Alcotest.test_case "admission error reports configured limit" `Quick
            test_h2_connection_admission_error_reports_configured_limit;
          Alcotest.test_case "early response beats blocked upload" `Quick
            test_h2_connection_returns_early_response;
          Alcotest.test_case "cancelled upload releases body" `Quick
            test_h2_connection_cancelled_upload_releases_body;
          Alcotest.test_case "stream upload observes flow control" `Quick
            test_h2_connection_stream_upload_observes_flow_control;
          Alcotest.test_case "cancelled fixed request releases stream" `Quick
            test_h2_connection_cancelled_fixed_request_releases_stream;
          Alcotest.test_case "cancelled body read preserves connection" `Quick
            test_h2_connection_cancelled_body_read_preserves_connection;
          Alcotest.test_case "completed error response releases switch" `Quick
            test_h2_connection_completed_error_response_does_not_hold_switch;
          Alcotest.test_case "continues after informational headers" `Quick
            test_h2_connection_continues_after_informational_headers;
          Alcotest.test_case "filter passes PUSH_PROMISE continuation" `Quick
            test_h2_informational_filter_passes_push_promise_continuation;
          Alcotest.test_case "informational filter passthrough is not global"
            `Quick test_h2_informational_filter_passthrough_is_not_global;
          Alcotest.test_case "GOAWAY mid-body completes existing stream" `Quick
            test_h2_connection_goaway_mid_body_completes_existing_stream;
          Alcotest.test_case "timeout one request preserves connection" `Quick
            test_h2_connection_timeout_preserves_connection;
          Alcotest.test_case "switch close does not fire security error" `Quick
            test_h2_connection_switch_close_does_not_fire_security_error;
          Alcotest.test_case "failure kind on switch close is not protocol violation" `Quick
            test_h2_connection_failure_kind_on_switch_close_is_not_protocol_violation;
          Alcotest.test_case "body error on switch close is connection closed" `Quick
            test_h2_connection_body_error_on_switch_close_is_connection_closed;
          Alcotest.test_case "failure handler exception skips others" `Quick
            test_h2_connection_failure_handler_exception_skips_others;
        ] );
      ( "h2-security",
        [
          Alcotest.test_case "SETTINGS churn reader" `Quick
            test_h2_security_settings_churn_reader;
          Alcotest.test_case "HPACK block cap" `Quick
            test_h2_security_hpack_block_cap;
          Alcotest.test_case "CONTINUATION cap" `Quick
            test_h2_security_continuation_cap;
          Alcotest.test_case "initial HEADERS fragment cap" `Quick
            test_h2_security_rejects_oversized_initial_headers_fragment;
          Alcotest.test_case "PUSH_PROMISE fragment cap" `Quick
            test_h2_security_rejects_oversized_push_promise_fragment;
          Alcotest.test_case "GOAWAY churn" `Quick
            test_h2_security_goaway_churn;
          Alcotest.test_case "header churn" `Quick
            test_h2_security_header_churn;
          Alcotest.test_case "many normal response headers" `Quick
            test_h2_security_allows_many_normal_response_headers;
          Alcotest.test_case "forgets completed stream headers" `Quick
            test_h2_security_forgets_completed_stream_headers;
          Alcotest.test_case "multiplexer release forgets stream headers" `Quick
            test_h2_security_multiplexer_release_forgets_stream_headers;
          Alcotest.test_case "header normalization edges" `Quick
            test_h2_security_header_normalization_edges;
        ] );
      ( "h2-multiplexer",
        [
          Alcotest.test_case "reads server response" `Quick
            test_h2_multiplexer_reads_server_response;
          Alcotest.test_case "default reader accepts max DATA frame" `Quick
            test_h2_default_reader_accepts_max_sized_data_frame;
          Alcotest.test_case "body stream releases on EOF" `Quick
            test_h2_body_stream_releases_on_eof;
          Alcotest.test_case "body stream reads inline data" `Quick
            test_h2_body_stream_reads_inline_data_after_header_pump;
          Alcotest.test_case "response trailers" `Quick
            test_h2_multiplexer_delivers_response_trailers;
          Alcotest.test_case "body stream discard releases" `Quick
            test_h2_body_stream_discard_releases_active_stream;
          Alcotest.test_case "100 concurrent GETs" `Quick
            test_h2_multiplexer_sustains_100_concurrent_gets;
          Alcotest.test_case "upload flow-control resumes" `Quick
            test_h2_multiplexer_upload_flow_control_resumes;
          Alcotest.test_case "server reset admission release" `Quick
            test_h2_multiplexer_server_reset_admission_release;
          Alcotest.test_case "release forgets stream headers" `Quick
            test_h2_multiplexer_release_forgets_informational_filter_stream;
          Alcotest.test_case "client cancel releases stream" `Quick
            test_h2_multiplexer_client_cancel_releases_stream;
          Alcotest.test_case "release closes open request body" `Quick
            test_h2_multiplexer_release_closes_open_request_body;
          Alcotest.test_case "buffer-full returns security error" `Quick
            test_h2_multiplexer_buffer_full_is_security_error;
          Alcotest.test_case "GOAWAY rejects new streams" `Quick
            test_h2_multiplexer_rejects_after_goaway;
          Alcotest.test_case "body_stream_async bounded recursion" `Quick
            test_h2_body_stream_async_bounded_recursion;
        ] );
    ]
