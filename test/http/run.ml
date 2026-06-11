open Test_eta_http_h1_write
open Test_eta_http_transport
open Test_eta_http_h1_client
open Test_eta_http_h1_server
open Test_eta_http_ws
open Test_eta_http_tls
open Test_eta_http_h2_writer
open Test_eta_http_h2_connection
open Test_eta_http_h2_multiplexer
open Test_eta_http_h2_server
open Test_eta_http_h2_security

let () =
  Alcotest.run "eta-http"
    [
      ( "client",
        [
          Alcotest.test_case "make_h1 request path" `Quick
            test_client_make_h1_request_path;
          Alcotest.test_case "runtime service h1 request" `Quick
            test_eio_runtime_service_h1_request;
          Alcotest.test_case "rejects cross-domain use" `Quick
            test_client_rejects_cross_domain_use;
        ] );
      ( "h1-write",
        [
          Alcotest.test_case "flow rejects invalid Content-Length framing" `Quick
            test_h1_writer_rejects_invalid_content_length_framing;
          Alcotest.test_case "flow rejects Transfer-Encoding fixed body" `Quick
            test_h1_writer_rejects_transfer_encoding_for_fixed_body;
          Alcotest.test_case "flow stream override does not reframe fixed body" `Quick
            test_h1_writer_stream_override_does_not_reframe_fixed_body;
          Alcotest.test_case "flow matches string writer" `Quick
            test_h1_writer_flow_matches_string_writer;
          Alcotest.test_case "flow write failure is typed" `Quick
            test_h1_writer_flow_write_failure_is_typed;
          Alcotest.test_case "flow write cancellation propagates" `Quick
            test_h1_writer_flow_write_cancellation_propagates;
          Alcotest.test_case "flow rejects header injection" `Quick
            test_h1_writer_rejects_header_injection;
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
          Alcotest.test_case "rejects unknown-length stream Content-Length" `Quick
            test_h1_client_rejects_unknown_stream_content_length;
          Alcotest.test_case
            "rejects unknown-length stream unsupported Transfer-Encoding" `Quick
            test_h1_client_rejects_unknown_stream_unsupported_transfer_encoding;
          Alcotest.test_case "rejects non-final chunked Transfer-Encoding" `Quick
            test_h1_client_rejects_non_final_chunked_transfer_encoding;
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
          Alcotest.test_case "response head read exception is typed and releases"
            `Quick test_h1_response_head_read_exception_is_typed_and_releases;
          Alcotest.test_case "body read exception is typed" `Quick
            test_h1_body_read_exception_is_typed;
        ] );
      ( "h1-server",
        [
          Alcotest.test_case "GET fixed response" `Quick
            test_h1_server_connection_get_fixed_response;
          Alcotest.test_case "POST reads fixed body" `Quick
            test_h1_server_connection_post_reads_fixed_body;
          Alcotest.test_case "streams fixed-length response" `Quick
            test_h1_server_connection_streams_fixed_length_response;
          Alcotest.test_case "streams chunked response with trailers" `Quick
            test_h1_server_connection_streams_chunked_response_with_trailers;
          Alcotest.test_case "stream write failure releases body" `Quick
            test_h1_server_connection_releases_stream_on_write_failure;
          Alcotest.test_case "keep-alive sequential requests" `Quick
            test_h1_server_connection_keeps_alive_for_sequential_requests;
          Alcotest.test_case "keep-alive preserves pipelined bytes" `Quick
            test_h1_server_connection_keeps_pipelined_request_bytes;
          Alcotest.test_case "drains unread body for reuse" `Quick
            test_h1_server_connection_drains_unread_body_for_reuse;
          Alcotest.test_case "idle timeout closes keep-alive" `Quick
            test_h1_server_connection_idle_timeout_closes_keep_alive;
          Alcotest.test_case "run_h1_on_socket plain GET" `Quick
            test_h1_server_run_on_socket_plain_get;
        ] );
      ( "ws",
        [
          Alcotest.test_case "upgrade reads inbound text" `Quick
            test_ws_connect_reads_inbound_text;
          Alcotest.test_case "oversized frame rejected before payload read" `Quick
            test_ws_rejects_oversized_frame_before_payload_read;
          Alcotest.test_case "64-bit length with MSB set rejected as protocol error"
            `Quick test_ws_rejects_64bit_length_with_msb_set_as_protocol_error;
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
          Alcotest.test_case "invalid peer close code is protocol error" `Quick
            test_ws_invalid_peer_close_code_is_protocol_error;
          Alcotest.test_case "rejects invalid UTF-8 text frame" `Quick
            test_ws_rejects_invalid_utf8_text_frame;
          Alcotest.test_case "rejects invalid UTF-8 close reason" `Quick
            test_ws_rejects_invalid_utf8_close_reason;
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
      ( "tls",
        [
          Alcotest.test_case "OpenSSL SSL finalizer ownership" `Quick
            test_openssl_ssl_finalizer_keeps_ctx_ownership_separate;
          Alcotest.test_case "OpenSSL server ctx loads cert/key" `Quick
            test_openssl_server_ctx_loads_cert_key_and_creates_ssl;
          Alcotest.test_case "OpenSSL server ALPN selects h2" `Quick
            test_openssl_server_alpn_selects_client_protocol;
          Alcotest.test_case "Tls_eio server_of_flow epoch" `Quick
            test_tls_eio_server_of_flow_handshake_epoch;
          Alcotest.test_case "ALPN server dispatch routes" `Quick
            test_alpn_server_dispatch_routes_and_closes_unsupported;
          Alcotest.test_case "HTTPS server H1 ALPN request" `Quick
            test_https_server_h1_alpn_request;
          Alcotest.test_case "HTTPS server H2 ALPN request" `Quick
            test_https_server_h2_alpn_request;
          Alcotest.test_case "OpenSSL server ctx rejects invalid cert" `Quick
            test_openssl_server_ctx_rejects_invalid_cert;
          Alcotest.test_case "OpenSSL server ctx rejects invalid key" `Quick
            test_openssl_server_ctx_rejects_invalid_key;
          Alcotest.test_case "server config records TLS material" `Quick
            test_tls_server_config_records_cert_key_and_alpn;
          Alcotest.test_case "handshake enters SSL mutex" `Quick
            test_tls_handshake_enters_ssl_mutex_before_openssl;
          Alcotest.test_case "client uses IP peer identity" `Quick
            test_tls_client_of_flow_uses_ip_identity;
        ] );
      ( "h2-writer",
        [
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
      ( "h2-server",
        [
          Alcotest.test_case "h2c fixed, echo, unread body, stream, trailers" `Quick
            test_h2c_server_fixed_response_and_echo_body;
          Alcotest.test_case "generic h2 runner carries connection metadata" `Quick
            test_h2_server_connection_run_uses_connection_metadata;
          Alcotest.test_case "h2c bounded request body drain" `Quick
            test_h2c_server_drain_up_to_discard_waits_for_body;
          Alcotest.test_case "h2c connection close fails pending body read" `Quick
            test_h2c_server_connection_close_fails_pending_body_read;
          Alcotest.test_case "h2c server handle graceful shutdown" `Quick
            test_h2c_server_handle_graceful_shutdown_waits_for_stream;
          Alcotest.test_case "h2c read exception closes typed" `Quick
            test_h2c_server_read_exception_closes_typed;
          Alcotest.test_case "h2c write exception closes typed" `Quick
            test_h2c_server_write_exception_closes_typed;
        ] );
      ( "h2-security",
        [
          Alcotest.test_case "SETTINGS churn reader" `Quick
            test_h2_security_settings_churn_reader;
        ] );
      ( "h2-multiplexer",
        [
          Alcotest.test_case "reads server response" `Quick
            test_h2_multiplexer_reads_server_response;
          Alcotest.test_case "read exception is typed result" `Quick
            test_h2_multiplexer_read_exception_is_typed_result;
          Alcotest.test_case "default reader accepts max DATA frame" `Quick
            test_h2_default_reader_accepts_max_sized_data_frame;
          Alcotest.test_case "release forgets stream headers" `Quick
            test_h2_multiplexer_release_forgets_informational_filter_stream;
          Alcotest.test_case "buffer-full returns security error" `Quick
            test_h2_multiplexer_buffer_full_is_security_error;
          Alcotest.test_case "body_stream_async bounded recursion" `Quick
            test_h2_body_stream_async_bounded_recursion;
        ] );
    ]
