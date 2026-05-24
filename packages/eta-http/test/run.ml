open Test_eta_http_core
open Test_eta_http_body
open Test_eta_http_url
open Test_eta_http_h1_write
open Test_eta_http_h1_parse
open Test_eta_http_transport
open Test_eta_http_h1_client
open Test_eta_http_retry
open Test_eta_http_observability
open Test_eta_http_tls
open Test_eta_http_h2_state
open Test_eta_http_h2_writer
open Test_eta_http_h2_multiplexer
open Test_eta_http_h2_security
open Test_eta_http_alpn_dispatch

let () =
  Alcotest.run "eta-http"
    [
      ("skeleton", [ Alcotest.test_case "loads" `Quick test_skeleton_loads ]);
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
          Alcotest.test_case "read_all caps default" `Quick
            test_body_stream_read_all_caps_default;
          Alcotest.test_case "chunked trailers" `Quick
            test_chunked_decodes_trailers;
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
          Alcotest.test_case "DNS error semconv" `Quick
            test_observability_dns_error_semconv;
          Alcotest.test_case "TLS error semconv" `Quick
            test_observability_tls_error_semconv;
          Alcotest.test_case "retry success spans" `Quick
            test_observability_retry_success_spans;
          Alcotest.test_case "redirect semconv" `Quick
            test_observability_redirect_semconv;
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
          Alcotest.test_case "flow matches string writer" `Quick
            test_h1_writer_flow_matches_string_writer;
          Alcotest.test_case "flow write failure is typed" `Quick
            test_h1_writer_flow_write_failure_is_typed;
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
          Alcotest.test_case "HEAD ignores chunked body headers" `Quick
            test_h1_client_head_ignores_chunked_body_headers;
          Alcotest.test_case "pool reuses healthy idle connection" `Quick
            test_h1_pool_reuses_healthy_idle_connection;
          Alcotest.test_case "pool rejects unhealthy idle connection" `Quick
            test_h1_pool_rejects_unhealthy_idle_connection;
          Alcotest.test_case "pool holds checkout until body EOF" `Quick
            test_h1_pool_holds_checkout_until_body_eof;
          Alcotest.test_case "pool discard releases checkout" `Quick
            test_h1_pool_discard_releases_checkout;
          Alcotest.test_case "pool cancellation releases checkout" `Quick
            test_h1_pool_request_cancellation_releases_checkout;
        ] );
      ( "transport",
        [
          Alcotest.test_case "resolve stream success" `Quick
            test_transport_resolve_stream_success;
          Alcotest.test_case "resolve stream empty typed" `Quick
            test_transport_resolve_stream_empty_is_typed;
          Alcotest.test_case "connect tcp success" `Quick
            test_transport_connect_tcp_success;
          Alcotest.test_case "connect tcp failure typed" `Quick
            test_transport_connect_tcp_failure_is_typed;
          Alcotest.test_case "connect tls closes flow on failure" `Quick
            test_transport_connect_tls_closes_flow_on_failure;
        ] );
      ( "alpn",
        [
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
        ] );
      ( "h2-admission",
        [
          Alcotest.test_case "cancelled counts until release" `Quick
            test_h2_admission_counts_cancelled_until_release;
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
      ( "h2-security",
        [
          Alcotest.test_case "SETTINGS churn reader" `Quick
            test_h2_security_settings_churn_reader;
          Alcotest.test_case "HPACK block cap" `Quick
            test_h2_security_hpack_block_cap;
          Alcotest.test_case "CONTINUATION cap" `Quick
            test_h2_security_continuation_cap;
          Alcotest.test_case "GOAWAY churn" `Quick
            test_h2_security_goaway_churn;
          Alcotest.test_case "header churn" `Quick
            test_h2_security_header_churn;
          Alcotest.test_case "header normalization edges" `Quick
            test_h2_security_header_normalization_edges;
        ] );
      ( "h2-multiplexer",
        [
          Alcotest.test_case "reads server response" `Quick
            test_h2_multiplexer_reads_server_response;
          Alcotest.test_case "body stream releases on EOF" `Quick
            test_h2_body_stream_releases_on_eof;
          Alcotest.test_case "body stream reads inline data" `Quick
            test_h2_body_stream_reads_inline_data_after_header_pump;
          Alcotest.test_case "body stream discard releases" `Quick
            test_h2_body_stream_discard_releases_active_stream;
          Alcotest.test_case "100 concurrent GETs" `Quick
            test_h2_multiplexer_sustains_100_concurrent_gets;
          Alcotest.test_case "upload flow-control resumes" `Quick
            test_h2_multiplexer_upload_flow_control_resumes;
          Alcotest.test_case "server reset admission release" `Quick
            test_h2_multiplexer_server_reset_admission_release;
          Alcotest.test_case "client cancel releases stream" `Quick
            test_h2_multiplexer_client_cancel_releases_stream;
          Alcotest.test_case "buffer-full returns security error" `Quick
            test_h2_multiplexer_buffer_full_is_security_error;
          Alcotest.test_case "GOAWAY rejects new streams" `Quick
            test_h2_multiplexer_rejects_after_goaway;
        ] );
    ]

