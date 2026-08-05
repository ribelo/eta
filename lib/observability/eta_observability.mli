(** Eta observability SDK.

    This optional package owns the application-facing tracing, logging, metrics,
    and propagation DSL. Effects remain ordinary {!Eta.Effect.t} blueprints and
    are interpreted by the root Eta runtime through its capability contracts. *)

open Eta

module Log_level = Log_level
module Logger = Logger
module Meter = Meter
module Tracer = Tracer
module Trace_context = Trace_context

val with_error_pp :
  (Format.formatter -> 'err -> unit) -> ('a, 'err) Effect.t -> ('a, 'err) Effect.t
(** Pretty-print typed failures for observability span status and exception
    events on the wrapped effect. The printer is scoped to this effect's error
    channel. Output is rendered at most once per span status or exception
    event. The printer must be total; a raising [error_pp] becomes a defect
    through the ordinary capture path. When no printer is installed, the
    default ["<typed failure>"] status text is used. *)

val suppress_observability : ('a, 'err) Effect.t -> ('a, 'err) Effect.t
(** Run the wrapped effect without emitting tracer, logger, or meter events
    from inside the subtree.

    This is intended for observability exporters and other observer backends
    that must call Eta-based libraries without recursively observing their own
    export path. It does not change typed errors, resource finalization, or
    defect diagnostics. *)

val with_logger : Capabilities.logger -> ('a, 'err) Effect.t -> ('a, 'err) Effect.t
(** Dynamically replace the fiber-local log sink for [body]. Children inherit
    it at fork without join-merge. Success, typed failure, defect, and
    interruption restore it. Innermost wins and
    [par] siblings are isolated. Each log chooses its sink when called; earlier
    emissions are unchanged. A daemon retains its fork-time sink after this
    scope exits. [annotate_logs] adds attributes and [with_minimum_log_level]
    filters before {!intercept_log} transforms the record for this sink. *)

val with_tracer : Capabilities.tracer -> ('a, 'err) Effect.t -> ('a, 'err) Effect.t
(** Dynamically replace the fiber-local tracer for [body]. Children inherit it
    at fork without join-merge. Success, typed failure, defect, and interruption
    restore it. Innermost wins and
    [par] siblings are isolated. [named]/[fn] capture it when opening a span, so
    an open span is unchanged by a later override. A daemon retains its
    fork-time tracer after this scope exits. Span operations for that span use
    the captured tracer through completion. *)

val named :
  ?kind:Capabilities.span_kind ->
  ?error_pp:(Format.formatter -> 'err -> unit) ->
  string ->
  ('a, 'err) Effect.t ->
  ('a, 'err) Effect.t
(** [named name body] attaches a span name for tracing around [body].

    [?kind] defaults to {!Capabilities.Internal}. [?error_pp] pretty-prints
    typed failures for this span's status and exception events; omit it to keep
    ["<typed failure>"]. Output is rendered at most once per span status or
    exception event. The printer must be total; a raising [error_pp] becomes a
    defect through the ordinary capture path. *)

val annotate : key:string -> value:string -> ('a, 'err) Effect.t -> ('a, 'err) Effect.t
(** Attach a string attribute to the active span. If no span is active, the
    attribute is buffered and attached to the next span opened by the same
    fiber. The same annotation is also included in defect diagnostics produced
    by the wrapped effect. *)

val annotate_all : (string * string) list -> ('a, 'err) Effect.t -> ('a, 'err) Effect.t
(** Attach several span attributes with the same semantics as {!annotate}. The
    list order is preserved. *)

val annotate_all_lazy :
  (unit -> (string * string) list) -> ('a, 'err) Effect.t -> ('a, 'err) Effect.t
(** Like {!annotate_all}, but the attribute list is only built when tracing is
    enabled in the active runtime. Use for hot paths where computing the
    attributes (e.g. formatting numbers/URLs per request) is wasted when no
    tracer is installed. When tracing is disabled the thunk is never called. *)

val is_tracing_enabled : (bool, 'err) Effect.t
(** Resolves to effective tracing admission in the active runtime. It is [false]
    when tracing is suppressed by {!suppress_observability}, even if a tracer is
    installed. Use it to skip building span wrappers on hot paths when no tracer
    will record them. *)

val event : ?attrs:(string * string) list -> string -> (unit, 'err) Effect.t
(** Add an event to the currently active span. If tracing is disabled or no span
    is active, this is a no-op. Use this for structured progress markers inside
    a span; use {!log} for log records and {!metric_update} for metrics. *)

val with_result_attrs :
  ok_attrs:('a -> (string * string) list) ->
  err_attrs:('err -> (string * string) list) ->
  ('a, 'err) Effect.t ->
  ('a, 'err) Effect.t
(** Attach attributes derived from the effect outcome to the active span and
    preserve the original result.

    [ok_attrs] is evaluated after success. [err_attrs] is evaluated for every
    typed [Cause.Fail] in the failure cause. Defects and interruption are not
    passed to [err_attrs]. Both callbacks must be total. If [ok_attrs] raises,
    its exception replaces the success as a defect. If [err_attrs] raises, the
    original failure remains primary and the exception is attached as a
    suppressed finalizer defect.

    The attributes are recorded only when a span is active at the point the
    wrapped effect settles. Put this combinator inside {!named} or {!fn} when
    the attributes should land on that span:

    {[
      named "load.rows"
        (with_result_attrs
           ~ok_attrs:(fun rows -> [ ("row_count", string_of_int (List.length rows)) ])
           ~err_attrs:(fun `Db_error -> [ ("result", "db_error") ])
           load_rows)
    ]} *)

val link_span :
  ?attrs:(string * string) list ->
  trace_id:string ->
  span_id:string ->
  ('a, 'err) Effect.t ->
  ('a, 'err) Effect.t
(** Attach a {!Capabilities.span_link} to the span opened by [body]. If [body]
    has no enclosing {!named} span, the link buffers and attaches to the next
    one (mirrors the buffered-attribute semantics). *)

val with_external_parent :
  trace_id:string -> span_id:string -> ('a, 'err) Effect.t -> ('a, 'err) Effect.t
(** Compatibility wrapper for {!with_context} when only a trace ID and parent
    span ID are available. New boundary code should prefer {!Trace_context.extract}
    plus {!with_context} so trace flags, tracestate, and baggage are preserved. *)

val with_context :
  Capabilities.trace_context -> ('a, 'err) Effect.t -> ('a, 'err) Effect.t
(** Run [body] with an inbound or otherwise external trace context. When no
    active in-process span exists, the next opened {!named} span uses this
    context as parent; an active in-process parent takes precedence.
    Parent-based sampling sees the installed context's sampled flag, and
    baggage/tracestate remain visible through {!current_context}. *)

val current_span : (Capabilities.span_info option, 'err) Effect.t
(** Yield the {!Capabilities.span_info} of the currently active span on this
    fiber, or [None] if none is open. *)

val current_context : (Capabilities.trace_context option, 'err) Effect.t
(** Yield the current propagation context. When a span is active this is that
    span's context; otherwise it is the ambient context installed by
    {!with_context}, if any. *)

val annotate_logs : (string * string) list -> ('a, 'err) Effect.t -> ('a, 'err) Effect.t
(** Run an effect with scoped log attributes.

    [body |> annotate_logs attrs] appends [attrs] to every {!log} record emitted
    in [body]'s dynamic scope. Nested scopes accumulate from outermost to
    innermost, and scoped attributes are merged before per-call [log ~attrs]
    attributes. The binding is runtime-local/fiber-local and does not affect
    span attributes installed by {!annotate} or {!annotate_all}. *)

val with_minimum_log_level :
  Capabilities.log_level -> ('a, 'err) Effect.t -> ('a, 'err) Effect.t
(** Run an effect with a scoped minimum log level.

    [body |> with_minimum_log_level Warn] drops {!log} records below [Warn]
    before they reach the runtime logger. Nested scopes use the stricter
    effective minimum for the current dynamic scope. The binding is
    runtime-local/fiber-local and affects only {!log} and the level helpers
    below; logger-level filters still apply independently after a record is
    admitted by this scope. *)

type 'a intercept = Keep | Drop | Replace of 'a
(** Result of an observability interceptor. [Keep] passes the input unchanged
    and [Drop] stops the pipeline; both are immediate and allocation-free.
    [Replace value] passes [value] to the next interceptor and allocates only
    its unary variant block. *)

val intercept_log :
  (Capabilities.log_record -> Capabilities.log_record intercept) ->
  ('a, 'err) Effect.t ->
  ('a, 'err) Effect.t
(** Fiber-locally transform records emitted in [body]'s dynamic subtree. The
    order is minimum-level filter, scoped/per-call attributes, interceptors,
    then the currently bound logger. Nested interceptors run outermost first;
    [Drop] drops the record and skips later interceptors. Thus
    [intercept_log scrub (with_logger sink body)] and
    [with_logger sink (intercept_log scrub body)] both scrub before [sink]. A
    raising transform becomes a defect through ordinary capture. Each active
    interceptor adds one function call per record; [Keep] does not box or
    allocate a replacement record on the emission fast path. *)

val log :
  ?level:Capabilities.log_level ->
  ?attrs:(string * string) list ->
  string ->
  (unit, 'err) Effect.t
(** Emit a structured log record to the runtime's logger. The runtime
    automatically populates the record's [trace_id]/[span_id] from the
    active span and [ts_ms] from the runtime's clock. Scoped attributes from
    {!annotate_logs} are prepended to the per-call [attrs]. Records below the
    scoped {!with_minimum_log_level}, when one is active, are dropped before
    reaching the logger. *)

val logf :
  ?level:Capabilities.log_level ->
  ?attrs:(string * string) list ->
  (Format.formatter -> unit) ->
  (unit, 'err) Effect.t
(** Formatted {!log}; the formatter runs once per admitted interpretation,
    gated by runtime logging-enabled and the scoped {!with_minimum_log_level} —
    logger-owned filters such as {!Logger.with_min_level} run later and cannot
    suppress formatting. Work and arguments inside the formatter are deferred
    (those evaluated before [logf] remain eager). Its captured values are
    retained for the blueprint's lifetime.
    Attributes and intercepts follow [log]; [Drop] occurs after formatting, and a
    raise becomes a defect through ordinary capture. *)

val log_trace :
  ?attrs:(string * string) list -> string -> (unit, 'err) Effect.t
(** Emit a structured log record at [Trace] level. *)

val log_debug :
  ?attrs:(string * string) list -> string -> (unit, 'err) Effect.t
(** Emit a structured log record at [Debug] level. *)

val log_info : ?attrs:(string * string) list -> string -> (unit, 'err) Effect.t
(** Emit a structured log record at [Info] level. *)

val log_warn : ?attrs:(string * string) list -> string -> (unit, 'err) Effect.t
(** Emit a structured log record at [Warn] level. *)

val log_error :
  ?attrs:(string * string) list -> string -> (unit, 'err) Effect.t
(** Emit a structured log record at [Error] level. *)

val log_fatal :
  ?attrs:(string * string) list -> string -> (unit, 'err) Effect.t
(** Emit a structured log record at [Fatal] level. *)

val intercept_metric :
  (Capabilities.metric_point -> Capabilities.metric_point intercept) ->
  ('a, 'err) Effect.t ->
  ('a, 'err) Effect.t
(** Fiber-locally transform metric points emitted in [body]'s dynamic subtree
    after each point is built and before the current meter. Nested interceptors
    run outermost first; [Drop] drops the point and skips later interceptors. A
    raising transform becomes a defect through ordinary capture. Each active
    interceptor adds one function call per point; [Keep] does not box or
    allocate a replacement point on the emission fast path. *)

val metric_update :
  ?description:string ->
  ?unit_:string ->
  ?attrs:(string * string) list ->
  name:string ->
  kind:Capabilities.metric_kind ->
  Capabilities.metric_value ->
  (unit, 'err) Effect.t
(** Records a runtime metric observation, not part of the effect's success value
    or typed error channel. Numeric instruments use [Number _]; frequency uses
    [Category _]. Runtimes without a meter may ignore it. Prefer the typed
    helpers below for ordinary instrumentation. *)

val metric_counter :
  ?description:string ->
  ?unit_:string ->
  ?attrs:(string * string) list ->
  name:string ->
  ?monotonic:bool ->
  Capabilities.metric_number ->
  (unit, 'err) Effect.t
(** Record a counter observation. [monotonic=true] records an increment;
    [monotonic=false] records the latest cumulative value. *)

val metric_gauge :
  ?description:string ->
  ?unit_:string ->
  ?attrs:(string * string) list ->
  name:string ->
  Capabilities.metric_number ->
  (unit, 'err) Effect.t
(** Record the latest gauge value. *)

val metric_frequency :
  ?description:string ->
  ?unit_:string ->
  ?attrs:(string * string) list ->
  name:string ->
  string ->
  (unit, 'err) Effect.t
(** Record one occurrence of a string/category value. *)

val metric_histogram :
  ?description:string ->
  ?unit_:string ->
  ?attrs:(string * string) list ->
  name:string ->
  boundaries:float list ->
  float ->
  (unit, 'err) Effect.t
(** Record one histogram sample using explicit bucket boundaries. *)

val metric_summary :
  ?description:string ->
  ?unit_:string ->
  ?attrs:(string * string) list ->
  name:string ->
  quantiles:float list ->
  max_age:Duration.t ->
  max_size:int ->
  float ->
  (unit, 'err) Effect.t
(** Record one summary sample with quantile and window configuration. *)

val metric_timer :
  ?description:string ->
  ?unit_:string ->
  ?attrs:(string * string) list ->
  name:string ->
  boundaries:float list ->
  ('a, 'err) Effect.t ->
  ('a, 'err) Effect.t
(** Time an effect and record its elapsed runtime as a histogram sample. The
    source effect's result, typed failure, defect, interruption, and finalizer
    diagnostics propagate normally. *)

type metric
(** Description of one metric observation before the runtime timestamp is
    attached. Use {!metric} to construct values for {!metric_updates} and
    {!metric_updates_lazy}. *)

val metric :
  ?description:string ->
  ?unit_:string ->
  ?attrs:(string * string) list ->
  name:string ->
  kind:Capabilities.metric_kind ->
  Capabilities.metric_value ->
  metric
(** Build one metric observation for batched metric emission. *)

val metric_updates : metric list -> (unit, 'err) Effect.t
(** Record several metric observations with one runtime timestamp. Runtimes
    without a meter ignore the batch. *)

val metric_updates_lazy : (unit -> metric list) -> (unit, 'err) Effect.t
(** Like {!metric_updates}, but the list is built only when the active runtime
    has a meter. Use this for hot paths where collecting stats or allocating
    metric attributes is wasted when metrics are disabled. *)

val here_attr : string * int * int * int -> ('a, 'err) Effect.t -> ('a, 'err) Effect.t
(** Intended for wrappers that pass [__POS__] through unchanged; synthesized
    locations make traces harder to correlate with source. *)

val fn :
  ?kind:Capabilities.span_kind ->
  ?error_pp:(Format.formatter -> 'err -> unit) ->
  ?attrs:(string * string) list ->
  string * int * int * int ->
  string ->
  ('a, 'err) Effect.t ->
  ('a, 'err) Effect.t
(** [fn __POS__ __FUNCTION__ body] names [body] after the current binding and
    records the source location as a [loc] span attribute. [?attrs] attaches
    additional attributes to the same span. [?error_pp] has the same rendering
    contract as {!named}: at most once per span status or exception event; must
    be total; a raising printer becomes a defect. *)
