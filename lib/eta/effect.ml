(** Public Effect implementation. *)

open Effect_core

include Effect_core
include Effect_resource
include Effect_concurrent
include Effect_supervisor_scope
include Effect_schedule

let with_runtime_binding key value eff =
  preserve eff @@ fun frame ->
  let runtime = { frame.runtime with capability_overrides_active = true } in
  frame.runtime.contract.Runtime_contract.local_with_binding key value @@ fun () ->
  eval { frame with runtime } eff

let with_clock clock eff =
  with_runtime_binding Runtime_core.clock_override clock eff

let with_random random eff =
  with_runtime_binding Runtime_core.random_override random eff
