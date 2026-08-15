(* Eta_component: spatiotemporal component runtime for Eta.

   The façade owns the public submodules fixed by the integrated handoff.
   Declaration storage, admission, the provider graph, the coordinators,
   reconciliation, replacement, diagnostics, and telemetry stay private to
   the package. *)

module Coeffect = Component_coeffect
module Requirement = Component_declaration.Requirement
module Provision = Component_declaration.Provision
module Activation = Component_activation
module Component = Component_declaration
module Entry_id = Component_entry_id
module Desired_state = Component_desired_state
module Source_revision = Component_source_revision
module Replacement = Component_replacement

module Diagnostics = struct
  include Component_diagnostics

  type t = Component_coordinator.diagnostics

  let snapshot = Component_coordinator.snapshot
  let await_change = Component_coordinator.await_change
end

module Context = struct
  type t = Component_coordinator.context

  type callback = Component_coordinator.callback =
    | Configuration_equivalence
    | Interception_merge of string

  type admission_error = Component_coordinator.admission_error =
    | Context_not_running
    | Duplicate_entry_id of Entry_id.t
    | Entry_kind_changed of Entry_id.t
    | Duplicate_provider of {
        coeffect : string;
        realm : string;
        entries : Entry_id.t list;
      }
    | Dependency_cycle of Entry_id.t list
    | Callback_failed of {
        callback : callback;
        failure : Diagnostics.Failure.t;
      }
    | Retry_not_available of Entry_id.t
    | Stale_source_revision of Source_revision.t
    | Stale_entry_incarnation of Entry_id.t
    | Stale_target_revision of Entry_id.t
    | Wrong_target_context of Entry_id.t
    | Component_identity_mismatch of Entry_id.t
    | Quarantined_instance of Entry_id.t

  let run = Component_coordinator.run
  let reconcile = Component_coordinator.reconcile
  let retry = Component_coordinator.retry
  let replace = Component_coordinator.replace
  let shutdown = Component_coordinator.shutdown
end
