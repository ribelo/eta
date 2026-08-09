(* Typed repo-private test probe for representation-sensitive keyed checks.

   The public signal graph stores a keyed family owner behind [Obj.t] to break
   the recursive module type. The single representation cast is isolated in
   [family]: it restores the exact [keyed_owner] type for the [Order.t]-keyed
   instance this probe wraps and validates the owner handle against the keyed
   signal. Every handle and comparison exposed here is typed; no consumer
   touches [Obj.t].

   [Signal] is the full instantiated graph and [Keyed] is the production
   public map adapter, so behavior exercised through this probe is the
   production path. *)

open Eta_signal_kernel

module Make
    (Observer_error : Eta_signal.Observer_error)
    (Order : Eta_signal_map.Map.Ordered_type)
    () =
struct
  module Signal = Graph.Make_impl (Observer_error) ()
  module Signal_map = Eta_signal_map_api.Make_package (Signal.Package)
  module Keyed = Signal_map.Keyed (Order)

  type family =
    | Family :
        (Order.t, 'data, 'input, 'output, 'output_map) Propagation.keyed_owner
        -> family

  type entry =
    | Entry :
        (Order.t, 'data, 'input, 'output, 'output_map) Propagation.keyed_owner
        * (Order.t, 'data, 'output) Propagation.keyed_child
        -> entry

  let family signal =
    let keyed_signal = Signal.raw_for_testing signal in
    match keyed_signal.Propagation.keyed_owner with
    | None -> None
    | Some packed_owner ->
        let owner :
            (Order.t, 'data, 'input, 'output, 'output_map) Propagation.keyed_owner =
          Obj.obj packed_owner
        in
        if
          owner.Propagation.keyed_signal.handle = keyed_signal.handle
          && Propagation.validate_handle owner.keyed_signal
        then Some (Family owner)
        else None

  let find (Family owner) key =
    match Propagation.keyed_find owner key with
    | None -> None
    | Some child -> Some (Entry (owner, child))

  let same_scope (Entry (_, left)) (Entry (_, right)) = left.scope == right.scope

  (* [data] and [output] carry existential type witnesses that differ between
     entries, so physical identity for those projections is compared through
     [Obj.repr]. The values are heap blocks (var and signal records), so
     [Obj.repr] preserves identity exactly. This is representation erasure
     internal to the probe; the exposed comparisons are typed. *)
  let same_source (Entry (_, left)) (Entry (_, right)) =
    Obj.repr left.data == Obj.repr right.data

  let same_data_signal (Entry (_, left)) (Entry (_, right)) =
    Obj.repr left.data.signal == Obj.repr right.data.signal

  let same_child_signal (Entry (_, left)) (Entry (_, right)) =
    Obj.repr left.output == Obj.repr right.output

  let stored_key_is (Entry (_, child)) key = child.key == key
  let scope_valid (Entry (_, child)) = Propagation.scope_valid child.scope

  let child_edge_count (Entry (owner, child)) =
    List.length
      (List.filter
         (fun (Propagation.P node) ->
           node.handle = owner.Propagation.keyed_signal.handle)
         child.output.dependents)

  let has_exact_child_edge entry = child_edge_count entry = 1

  let is_settled (Family owner) =
    owner.committed_input == owner.keyed_input.current
    &&
    let intact = ref true in
    Propagation.child_iter
      (fun child ->
        let entry = Entry (owner, child) in
        if
          (not (scope_valid entry))
          || child_edge_count entry <> 1
        then intact := false)
      owner.children;
    !intact

  let fail_next_precommit (Family owner) exn =
    Propagation.set_keyed_precommit owner (fun () -> raise exn)

  type commit_event =
    | Detached
    | Invalidated
    | Attached

  let record_commit_events (Family owner) record =
    Propagation.set_keyed_event_recorder owner (function
      | Propagation.Keyed_detached _ -> record Detached
      | Propagation.Keyed_invalidated _ -> record Invalidated
      | Propagation.Keyed_attached _ -> record Attached)

  type counter =
    | Reconciliation_count
    | Input_key_comparison_count
    | Input_diff_event_count
    | Child_visit_count
    | Provisional_addition_count
    | Committed_addition_count
    | Committed_removal_count
    | Reconciliation_rollback_count

  let saturate_counter counter =
    let counter =
      match counter with
      | Reconciliation_count -> `Reconciliation
      | Input_key_comparison_count -> `Input_key_comparison
      | Input_diff_event_count -> `Input_diff_event
      | Child_visit_count -> `Child_visit
      | Provisional_addition_count -> `Provisional_addition
      | Committed_addition_count -> `Committed_addition
      | Committed_removal_count -> `Committed_removal
      | Reconciliation_rollback_count -> `Reconciliation_rollback
    in
    Propagation.set_keyed_counter_for Signal.graph counter max_int
end
