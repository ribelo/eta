(** W3C Trace Context and baggage helpers.

    This module is intentionally small and dependency-free. It gives Effet
    runtimes a concrete propagation value that can be extracted from inbound
    HTTP-style headers, carried through fiber-local runtime context, and
    injected into outbound headers. *)

type t : immutable_data = Capabilities.trace_context = {
  trace_id : string;
  span_id : string;
  trace_flags : int;
  trace_state : (string * string) list;
  baggage : (string * string) list;
}
(** Propagation context for a remote or local span.

    [trace_id] is 32 lowercase hex characters, [span_id] is 16 lowercase hex
    characters, and [trace_flags] carries the W3C flags byte. The sampled bit is
    [trace_flags land 1]. *)

val sampled : t -> bool
(** [true] when the W3C sampled flag is set. *)

val make :
  ?trace_flags:int ->
  ?trace_state:(string * string) list ->
  ?baggage:(string * string) list ->
  trace_id:string ->
  span_id:string ->
  unit ->
  t option
(** Validate and build a context. Returns [None] for malformed all-zero or
    non-hex identifiers. *)

val extract : (string * string) list -> t option
(** Extract [traceparent], [tracestate], and [baggage] from HTTP-style headers.
    Header names are matched case-insensitively. Malformed [traceparent] values
    are rejected with [None]. *)

val inject : t -> (string * string) list
(** Produce lowercase W3C [traceparent], [tracestate], and [baggage] headers. *)
