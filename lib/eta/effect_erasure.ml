(* Effect_erasure is the audited bridge from private eff constructors to the
   public abstract Effect.t. Keep this cast here so public helper modules do
   not grow ad hoc Obj/%identity sites. *)

external effect_to_public : ('a, 'err) Effect_core.t -> ('a, 'err) Effect.t =
  "%identity"

(* Supervisor bridge: the GADT builders live in the private
   Effect_supervisor_scope module while Supervisor.Scope re-exposes them over
   the public abstract Effect supervisor types. The casts only cross module
   abstraction boundaries inside the eta library; representations match. *)

external supervisor_scope_to_public :
  ('s, 'a, 'err) Effect_supervisor_scope.supervisor_scope ->
  ('s, 'a, 'err) Effect.supervisor_scope = "%identity"

external supervisor_scope_with_child_to_public :
  ('s, ('s, 'err, 'a) Effect_supervisor_scope.supervisor_child, 'outer_err)
    Effect_supervisor_scope.supervisor_scope ->
  ('s, ('s, 'err, 'a) Effect.supervisor_child, 'outer_err)
    Effect.supervisor_scope = "%identity"

external supervisor_scope_of_public :
  ('s, 'a, 'err) Effect.supervisor_scope ->
  ('s, 'a, 'err) Effect_supervisor_scope.supervisor_scope = "%identity"

external supervisor_of_public :
  ('s, 'err) Effect.supervisor ->
  ('s, 'err) Effect_supervisor_scope.supervisor = "%identity"

external supervisor_child_of_public :
  ('s, 'err, 'a) Effect.supervisor_child ->
  ('s, 'err, 'a) Effect_supervisor_scope.supervisor_child = "%identity"

let supervisor_pure value =
  supervisor_scope_to_public (Effect_supervisor_scope.supervisor_pure value)

let supervisor_lift eff =
  supervisor_scope_to_public
    (Effect_supervisor_scope.supervisor_lift
       (Runtime_erasure.effect_of_public eff))

let supervisor_fail err =
  supervisor_scope_to_public (Effect_supervisor_scope.supervisor_fail err)

let supervisor_bind k eff =
  supervisor_scope_to_public
    (Effect_supervisor_scope.supervisor_bind
       (fun value -> supervisor_scope_of_public (k value))
       (supervisor_scope_of_public eff))

let supervisor_start supervisor eff =
  supervisor_scope_with_child_to_public
    (Effect_supervisor_scope.supervisor_start
       (supervisor_of_public supervisor)
       (supervisor_scope_of_public eff))

let supervisor_await child =
  supervisor_scope_to_public
    (Effect_supervisor_scope.supervisor_await
       (supervisor_child_of_public child))

let supervisor_cancel child =
  supervisor_scope_to_public
    (Effect_supervisor_scope.supervisor_cancel
       (supervisor_child_of_public child))

let supervisor_request_cancel child =
  supervisor_scope_to_public
    (Effect_supervisor_scope.supervisor_request_cancel
       (supervisor_child_of_public child))

let supervisor_failures supervisor =
  supervisor_scope_to_public
    (Effect_supervisor_scope.supervisor_failures
       (supervisor_of_public supervisor))

let supervisor_check supervisor =
  supervisor_scope_to_public
    (Effect_supervisor_scope.supervisor_check
       (supervisor_of_public supervisor))

let public_sync ~leaf_name t sync_fn =
  effect_to_public
    (Effect_core.sync_contract ~leaf_name t sync_fn)

let public_sync2 ~leaf_name value1 value2 sync_fn =
  effect_to_public
    (Effect_core.sync_contract2 ~leaf_name value1 value2 sync_fn)

let plain_sync1 value run =
  effect_to_public (Effect_core.sync1 value run)

let plain_sync2 value1 value2 run =
  effect_to_public (Effect_core.sync2 value1 value2 run)

let plain_sync3 value1 value2 value3 run =
  effect_to_public (Effect_core.sync3 value1 value2 value3 run)

let public_runtime ~leaf_name t run =
  effect_to_public
    (Effect_core.eval_contract ~leaf_name t run)
