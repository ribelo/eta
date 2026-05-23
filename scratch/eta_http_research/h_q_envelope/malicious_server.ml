type group = Q2 | Q5 | Allocator

type coverage =
  | H_d1_multiplexer
  | Adapter_policy_only
  | Deferred_missing_capability of string

type default = {
  knob : string;
  value : string;
  justification : string;
  error_variant : string;
}

type attack = {
  id : string;
  group : group;
  title : string;
  falsifier : string;
  coverage : coverage;
  default : default;
  expected_error_class : string;
  frames_per_second : int;
}

let group_to_string = function Q2 -> "H-Q2" | Q5 -> "H-Q5" | Allocator -> "H-Q5-alloc"

let coverage_to_string = function
  | H_d1_multiplexer -> "H-D1 multiplexer"
  | Adapter_policy_only -> "adapter policy only"
  | Deferred_missing_capability capability ->
      "deferred - missing capability " ^ capability

let mk_error id kind =
  Error.make ~protocol:Error.H2 ~method_:"GET"
    ~uri:("https://malicious.example.test/" ^ id)
    kind

let connection_closed id =
  mk_error id (Connection_closed { during = Http_response })

let response_idle id =
  mk_error id (Response_body_idle_timeout { timeout_ms = Some 10_000 })

let decode_error id codec message =
  mk_error id (Decode_error { codec; message })

let rst_rate id ~observed_per_second ~limit_per_second =
  mk_error id (Rst_rate_exceeded { observed_per_second; limit_per_second })

let stream_admission id ~limit =
  mk_error id (Stream_admission_rejected { limit })

let hpack_overflow id =
  mk_error id
    (Hpack_decode_overflow { decoded_bytes = 2 * 1024 * 1024; limit_bytes = 256 * 1024 })

let attack_error attack =
  match attack.id with
  | "headers_rst_every_stream" -> stream_admission attack.id ~limit:128
  | "goaway_mid_flight" -> connection_closed attack.id
  | "header_churn" ->
      decode_error attack.id "h2_headers" "response header change rate exceeded"
  | "stream_id_jumps" -> stream_admission attack.id ~limit:128
  | "rst_rate_exceeded" -> rst_rate attack.id ~observed_per_second:250 ~limit_per_second:100
  | "ping_flood" -> connection_closed attack.id
  | "settings_header_table_size_churn" ->
      decode_error attack.id "h2_settings" "SETTINGS_HEADER_TABLE_SIZE change rate exceeded"
  | "window_update_accounting" ->
      decode_error attack.id "h2_window_update" "WINDOW_UPDATE accounting limit exceeded"
  | "goaway_churn" -> connection_closed attack.id
  | "data_frame_slowloris" -> response_idle attack.id
  | "huffman_cpu_amplification" -> hpack_overflow attack.id
  | "header_normalization_edges" ->
      decode_error attack.id "h2_headers" "invalid response header name or value"
  | "allocator_pressure" ->
      decode_error attack.id "h2_allocator" "allocator pressure envelope exceeded"
  | _ -> connection_closed attack.id

let default ~knob ~value ~justification ~error_variant =
  { knob; value; justification; error_variant }
