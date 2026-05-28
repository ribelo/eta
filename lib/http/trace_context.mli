(** W3C trace-context helpers for eta-http requests. *)

val extract_request : Request.t -> Eta.Trace_context.t option
(** Extract [traceparent], [tracestate], and [baggage] from a request's headers.
    Malformed trace context returns [None], matching {!Eta.Trace_context.extract}. *)

val inject_request : Eta.Trace_context.t -> Request.t -> Request.t
(** Return a copy of the request with W3C trace-context headers set from [ctx].
    Existing [traceparent], [tracestate], and [baggage] headers are replaced. *)
