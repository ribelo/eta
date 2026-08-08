module Map = struct
  module type Ordered_type = Eta_signal_map_kernel.Ordered_type

  type 'a change = 'a Eta_signal_map_kernel.change =
    | Left of 'a
    | Right of 'a
    | Changed of 'a * 'a

  module type S = sig
    type key
    type 'a t

    val empty : 'a t
    val singleton : key -> 'a -> 'a t
    val of_list : (key * 'a) list -> ('a t, [ `Duplicate_key of key ]) result
    val is_empty : 'a t -> bool
    val cardinal : 'a t -> int
    val mem : key -> 'a t -> bool
    val find_opt : key -> 'a t -> 'a option
    val set : key -> 'a -> 'a t -> 'a t
    val remove : key -> 'a t -> 'a t
    val update : key -> ('a option -> 'a option) -> 'a t -> 'a t
    val fold : (key -> 'a -> 'acc -> 'acc) -> 'a t -> 'acc -> 'acc
    val to_list : 'a t -> (key * 'a) list
    val map : ('a -> 'b) -> 'a t -> 'b t
    val filter_mapi : (key -> 'a -> 'b option) -> 'a t -> 'b t
    val equal : ('a -> 'a -> bool) -> 'a t -> 'a t -> bool

    val fold_symmetric_diff :
      'a t ->
      'a t ->
      init:'acc ->
      f:('acc -> key -> 'a change -> 'acc) ->
      'acc
  end

  module Make (Order : Ordered_type) = Eta_signal_map_kernel.Make (Order)
end

module Keyed_map (M : Stdlib.Map.S) = struct
  type ('data, 'child) entry = {
    data : 'data;
    child : 'child;
  }

  let reconcile ~previous ~current ~equal ~create ~retain
      ~remove =
    M.merge
      (fun key previous current ->
        match previous, current with
        | None, None -> None
        | None, Some data ->
            Some { data; child = create key data }
        | Some entry, None ->
            remove key entry.data entry.child;
            None
        | Some entry, Some data ->
            let data_changed = not (equal entry.data data) in
            let child =
              retain key ~data_changed ~previous:entry.data
                ~current:data entry.child
            in
            Some { data; child })
      previous current

  let children entries =
    M.map (fun entry -> entry.child) entries
end

module type PACKAGE = Eta_signal.Package_graph

module Keyed_adapter (Package : PACKAGE) (Order : Map.Ordered_type) = struct
  module M = Map.Make (Order)
  module Kernel_map = Eta_signal_map_kernel.Make (Order)

  let mapi ?data_cutoff input ~f =
    let input_ops : (_, _, _) Package.input_ops =
      {
        Package.empty = M.empty;
        compare_key = Order.compare;
        fold_symmetric_diff =
          (fun left right ~on_compare ~init ~f:emit ->
          Kernel_map.fold_symmetric_diff_counted left right ~on_compare ~init
            ~f:(fun acc key -> function
              | Map.Left value -> emit acc key (Package.Left value)
              | Map.Right value -> emit acc key (Package.Right value)
              | Map.Changed (old_value, new_value) ->
                  emit acc key (Package.Changed (old_value, new_value))));
      }
    in
    let output_ops : (_, _, _) Package.output_ops =
      { Package.empty = M.empty; set = M.set; remove = M.remove }
    in
    Package.install
      (Package.stable_family ?data_cutoff ~input ~input_ops ~output_ops
         ~build:f ())
end

module Make (Observer_error : Eta_signal.Observer_error) () = struct
  module Signal = Eta_signal_kernel.Graph.Make_impl (Observer_error) ()
  include Signal

  module Keyed (Order : Map.Ordered_type) = struct
    include Keyed_adapter (Signal.Package) (Order)

    module Testing = struct
      type token = Obj.t

      type entry_identity = {
        keyed_key_token : token;
        keyed_scope_token : token;
        keyed_source_token : token;
        keyed_data_signal_token : token;
        keyed_child_signal_token : token;
        keyed_edge_attached : bool;
      }

      type event =
        | Detached of token
        | Invalidated of token
        | Attached of token

      type counter =
        | Reconciliation_count
        | Input_key_comparison_count
        | Input_diff_event_count
        | Child_visit_count
        | Provisional_addition_count
        | Committed_addition_count
        | Committed_removal_count
        | Reconciliation_rollback_count

      type atomic_fault = unit

      type work_class =
        | Sources
        | Scheduler
        | Observer_delivery
        | Timer_reconciliation
        | Cleanup

      let work_count _ = 0
      let raw signal = Signal.raw_for_testing signal

      let owner signal =
        let keyed_signal = raw signal in
        match keyed_signal.node.Eta_signal_kernel.Propagation.keyed_owner with
        | None -> None
        | Some packed_owner ->
            let owner : (_, _, _, _, _) Eta_signal_kernel.Propagation.keyed_owner =
              Obj.obj packed_owner
            in
            if
              owner.keyed_signal.handle = keyed_signal.handle
              && Eta_signal_kernel.Propagation.validate_handle owner.keyed_signal
            then Some owner
            else None

      let entry_identity signal key =
        match owner signal with
        | None -> None
        | Some owner -> (
            match Eta_signal_kernel.Propagation.keyed_find owner key with
            | None -> None
            | Some child ->
                Some
                  {
                    keyed_key_token = Obj.repr child.key;
                    keyed_scope_token = Obj.repr child.scope;
                    keyed_source_token = Obj.repr child.data;
                    keyed_data_signal_token = Obj.repr child.data.signal;
                    keyed_child_signal_token = Obj.repr child.output;
                    keyed_edge_attached = true;
                  })

      let scope_valid token =
        let scope : Eta_signal_kernel.Propagation.scope = Obj.obj token in
        scope.valid

      let pending signal =
        match owner signal with
        | None -> false
        | Some owner ->
            owner.committed_input != owner.keyed_input.node.current

      let set_preflight signal f =
        match owner signal with
        | None -> ()
        | Some owner -> owner.preflight <- Some f

      let set_atomic_fault _ = ()
      let signal_token signal = Obj.repr (raw signal)

      let signal_valid_token token =
        Eta_signal_kernel.Propagation.validate_handle (Obj.obj token : _ Eta_signal_kernel.Propagation.signal)

      let signal_demand_token token =
        let signal : _ Eta_signal_kernel.Propagation.signal = Obj.obj token in
        signal.node.demand

      let dependent_edge_count_token token =
        let signal : _ Eta_signal_kernel.Propagation.signal = Obj.obj token in
        List.length signal.node.dependents

      let topology_counter_snapshot () = ()
      let reset_counters () = ()

      let has_dependent_edge_token ~child ~parent =
        let child : _ Eta_signal_kernel.Propagation.signal = Obj.obj child in
        let parent : _ Eta_signal_kernel.Propagation.signal = Obj.obj parent in
        List.exists
          (fun (Eta_signal_kernel.Propagation.P node) -> node.handle = parent.handle)
          child.node.dependents

      let set_event_recorder signal record =
        match owner signal with
        | None -> ()
        | Some owner ->
            Eta_signal_kernel.Propagation.set_keyed_event_recorder owner (function
              | Eta_signal_kernel.Propagation.Keyed_detached scope ->
                  record (Detached (Obj.repr scope))
              | Eta_signal_kernel.Propagation.Keyed_invalidated scope ->
                  record (Invalidated (Obj.repr scope))
              | Eta_signal_kernel.Propagation.Keyed_attached scope ->
                  record (Attached (Obj.repr scope)))

      let set_counter counter value =
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
        Eta_signal_kernel.Propagation.set_keyed_counter_for Signal.graph counter value
    end
  end
end

module Make_package (Package : PACKAGE) = struct
  module Keyed (Order : Map.Ordered_type) = Keyed_adapter (Package) (Order)
end
