(** Unstable service-provider interface (SPI) for Eta runtime packages.

    This module is the single home for Eta's service-provider surface: the
    hooks that let runtime and optional backend packages attach operations to
    the current interpreter, plus runtime-owned daemon work.

    - This is not application API.
    - There is no compatibility guarantee: this surface may change or be
      removed in any release and does not carry the stability expectations of
      {!Effect}.
    - Usage requires justification at the runtime-package level: it exists for
      packages that implement or extend an Eta runtime backend.
    - It is not for application dependency injection: applications pass
      dependencies as ordinary OCaml values.

    Application code belongs to {!Effect}, {!Supervisor}, and the scoped
    concurrency and resource combinators. *)

val daemon : (unit, 'err) Effect.t -> (unit, 'err) Effect.t
(** Start runtime-owned finite background work on the runtime's outer switch.

    Daemons are for Eta modules that own a lifecycle beyond the caller's local
    scope, such as pool eviction loops and protocol readers. Application code
    should prefer {!Effect.with_background} when the work belongs to one
    request, server, stream, or resource scope.

    Failures bypass the typed result and are reported as runtime daemon
    diagnostics. Use {!Runtime.drain} to wait for currently running finite
    daemon work before process shutdown or tests that assert daemon effects. *)

module Expert : sig
  type context

  val make :
    ?leaf_name:string ->
    (context -> ('a, 'err) Exit.t) ->
    ('a, 'err) Effect.t
  (** Build a runtime-backed effect without exposing Eta's internal effect
      representation. Runtime-specific packages use this to attach operations
      to the current {!Runtime_contract.t}; ordinary user code should prefer the
      typed combinators in {!Effect}. *)

  val contract : context -> Runtime_contract.t
  (** Runtime contract selected by the current interpreter. *)

  val current_scope : context -> Runtime_contract.scope
  (** Current lexical runtime scope. *)

  val outer_scope : context -> Runtime_contract.scope
  (** Runtime boundary scope used for runtime-owned background work. *)

  val runtime_service : context -> 'a Runtime_contract.service_key -> 'a option
  (** Runtime-package service attached when the interpreter was created. *)

  val auto_instrument : context -> bool
  (** Whether runtime leaf auto-instrumentation is enabled. *)

  val instrument_leaf : context -> name:string -> (unit -> 'a) -> 'a
  (** Run a leaf body under Eta's standard runtime instrumentation. *)

  val emit_trace_event :
    context -> name:string -> attrs:(string * string) list -> unit
  (** Emit an event on the active span, if tracing is enabled and sampled. *)

  val record_metric :
    context ->
    name:string ->
    description:string ->
    unit_:string ->
    kind:Capabilities.metric_kind ->
    attrs:(string * string) list ->
    value:Capabilities.metric_value ->
    unit
  (** Record a metric point when runtime metrics are enabled. *)

  val fork_daemon : context -> (unit -> [ `Stop_daemon ]) -> unit
  (** Fork runtime-owned finite background work and include it in
      {!Runtime.drain} accounting. *)

  val eval : context -> ('a, 'err) Effect.t -> ('a, 'err) Exit.t
  (** Evaluate a child effect in the current runtime context. *)

  val eval_in_scope :
    context ->
    Runtime_contract.scope ->
    ('a, 'err) Effect.t ->
    ('a, 'err) Exit.t
  (** Evaluate a child effect in an explicit runtime scope. *)

  val exit_of_exn : context -> exn -> ('a, 'err) Exit.t
  (** Convert an unchecked exception raised by a custom operation into Eta's
      diagnostic cause using the current runtime settings. *)
end
(** Narrow extension point for runtime packages. This module is intentionally
    small: it lets optional packages implement backend-specific leaves while
    keeping the root [Effect.t] representation private. *)
