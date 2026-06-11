(** Byte-level HTTP/2 security envelope checks.

    This scanner observes raw HTTP/2 frame bytes before they are handed to
    [ocaml-h2]. It owns eta-http's cheap frame-envelope policy:
    SETTINGS and GOAWAY are connection-lifetime counters because either frame is
    rare on healthy client connections. Response HEADERS are counted per stream:
    long-lived multiplexed connections may legitimately see hundreds of normal
    responses, while repeated HEADERS transitions on the same stream remain a
    churn signal. Empty DATA and WINDOW_UPDATE frames are counted as cheap DoS
    envelopes. Header-block/CONTINUATION byte caps protect incomplete or
    oversized HPACK envelopes; HPACK decoding remains owned by [ocaml-h2]. *)

type config = {
  max_settings_per_connection : int;
  max_goaway_per_connection : int;
  max_rst_stream_per_connection : int;
  max_ping_per_connection : int;
  max_empty_data_frames_per_connection : int;
  max_window_update_per_connection : int;
  max_hpack_block_bytes : int;
  max_continuation_accumulator_bytes : int;
  max_response_headers_per_connection : int;
  (** Per-stream response HEADERS limit. The field name is retained for API
      compatibility; it no longer counts normal responses across the whole
      connection lifetime. *)
  max_header_name_bytes : int;
  max_header_value_bytes : int;
}

val default_config : config

type t

val create : ?config:config -> unit -> t

val complete_stream : t -> int -> unit
(** Forget per-stream response-header accounting for a stream that has
    completed, reset, or otherwise been released. *)

val observe :
  t ->
  Bigstringaf.t ->
  off:int ->
  len:int ->
  Error.kind option

val validate_headers : (string * string) list -> Error.kind option
