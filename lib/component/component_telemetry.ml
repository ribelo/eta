(* Built-in component telemetry.

   Telemetry is non-authoritative: emissions observe fixed operation
   categories, outcome categories, and durations only. No configuration,
   provider value, coeffect value, typed error value, rendered application
   cause, or entry/instance/generation/episode/fence identity appears in any
   emission. Labels come from the fixed vocabularies below, so metric label
   cardinality is bounded by construction.

   Coordinator code records events as data during state mutation; the
   coordinator loop flushes them through [Eta_observability] after the
   mutation completes. Telemetry never feeds back into coordinator state, so
   a sink that drops, buffers, reorders, or samples events — or telemetry
   disabled entirely — changes no lifecycle result, revision, snapshot, or
   settlement report. No application audit record is emitted automatically. *)

open Eta

let ( let* ) = Syntax.( let* )

type event =
  | Operation_admitted of string
  | Operation_rejected of string
  | Fence_completed of string * string * int option
  | Activation_settled of string
  | Instance_quarantined
  | Lifecycle of string

let operation_reconcile = "reconcile"
let operation_retry = "retry"
let operation_replace = "replace"
let operation_shutdown = "shutdown"

let outcome_label = function
  | `Quiescent -> "quiescent"
  | `Superseded -> "superseded"
  | `Rolled_back -> "rolled_back"
  | `Degraded -> "degraded"
  | `Restoration_failed -> "restoration_failed"
  | `Context_failed -> "context_failed"

let summary_label = function
  | `Completed -> "completed"
  | `Failed -> "failed"
  | `Interrupted -> "interrupted"
  | `Aborted -> "aborted"

let counter = Eta_observability.Meter.counter ~monotonic:true ()
let one = Eta_observability.Meter.number (Int 1)

let duration_histogram =
  Eta_observability.Meter.histogram
    ~boundaries:[ 1.; 10.; 100.; 1_000.; 10_000. ]

let emit_event event =
  match event with
  | Operation_admitted operation ->
      Eta_observability.metric_update ~name:"eta.component.operation"
        ~attrs:[ ("operation", operation); ("outcome", "admitted") ]
        ~kind:counter one
  | Operation_rejected operation ->
      Eta_observability.metric_update ~name:"eta.component.operation"
        ~attrs:[ ("operation", operation); ("outcome", "rejected") ]
        ~kind:counter one
  | Fence_completed (kind, outcome, started_ms) -> (
      let* () =
        Eta_observability.metric_update ~name:"eta.component.fence"
          ~attrs:[ ("kind", kind); ("outcome", outcome) ]
          ~kind:counter one
      in
      match started_ms with
      | None -> Effect.unit
      | Some started_ms ->
          let* now = Effect.now_ms in
          let duration = Float.of_int (Int.max 0 (now - started_ms)) in
          Eta_observability.metric_update ~name:"eta.component.fence.duration"
            ~unit_:"ms"
            ~attrs:[ ("kind", kind); ("outcome", outcome) ]
            ~kind:duration_histogram
            (Eta_observability.Meter.number (Float duration)))
  | Activation_settled outcome ->
      Eta_observability.metric_update ~name:"eta.component.activation"
        ~attrs:[ ("outcome", outcome) ] ~kind:counter one
  | Instance_quarantined ->
      Eta_observability.metric_update ~name:"eta.component.quarantine"
        ~kind:counter one
  | Lifecycle transition ->
      Eta_observability.log_debug
        ~attrs:[ ("transition", transition) ]
        "eta.component: context lifecycle transition"
