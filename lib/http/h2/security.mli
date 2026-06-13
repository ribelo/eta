(** Byte-level HTTP/2 security envelope checks.

    This scanner observes raw HTTP/2 frame bytes before they are handed to
    [ocaml-h2]. It owns eta-http's cheap frame-envelope policy: SETTINGS, PING,
    RST_STREAM, empty DATA, and WINDOW_UPDATE frames are rate-limited by a
    sliding monotonic-time window with high emergency lifetime ceilings. GOAWAY
    is counted while allowing valid graceful shutdown sequences with
    non-increasing [last_stream_id] values.
    Response HEADERS are counted per stream: long-lived multiplexed connections
    may legitimately see hundreds of normal responses, while repeated HEADERS
    transitions on the same stream remain a churn signal.
    Header-block/CONTINUATION byte caps protect incomplete or oversized HPACK
    envelopes; HPACK decoding remains owned by [ocaml-h2]. *)

type rate_limit = {
  burst : int;
  window_ms : int;
  max_per_connection : int option;
}

type config = {
  settings_rate : rate_limit;
  max_goaway_per_connection : int;
  rst_stream_rate : rate_limit;
  ping_rate : rate_limit;
  empty_data_rate : rate_limit;
  window_update_rate : rate_limit;
  max_hpack_block_bytes : int;
  max_continuation_accumulator_bytes : int;
  max_response_headers_per_stream : int;
  max_header_name_bytes : int;
  max_header_value_bytes : int;
}

val default_config : config

type t

val create : ?config:config -> unit -> t

type observation =
  | Pass
  | Connection_error of { code : int; kind : Error.kind }
  | Stream_error of { stream_id : int; code : int; kind : Error.kind }
  | Policy_close of { code : int; kind : Error.kind }

val complete_stream : t -> int -> unit
(** Forget per-stream response-header accounting for a stream that has
    completed, reset, or otherwise been released. *)

val tracked_header_streams : t -> int
(** Number of streams currently retained for per-stream header accounting. *)

val has_open_header_block : t -> bool
(** [true] when the scanner has observed HEADERS, PUSH_PROMISE, or
    CONTINUATION without END_HEADERS. EOF in this state is an incomplete HTTP/2
    header block. *)

val observe_result :
  t ->
  Bigstringaf.t ->
  off:int ->
  len:int ->
  now_ms:int64 ->
  observation

val validate_headers : (string * string) list -> Error.kind option
