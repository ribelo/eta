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

module Make (Observer_error : Eta_signal.Observer_error) () = struct
  module Signal = Eta_signal_kernel.Make (Observer_error) ()
  include Signal

  module Keyed (Order : Map.Ordered_type) = struct
    module M = Map.Make (Order)
    module Kernel_map = Eta_signal_map_kernel.Make (Order)

    let mapi ?data_cutoff input ~f =
      let input_ops : (_, _, _) Signal.Package.input_ops =
        {
          Signal.Package.empty = M.empty;
          compare_key = Order.compare;
          fold_symmetric_diff =
            (fun left right ~on_compare ~init ~f:emit ->
            Kernel_map.fold_symmetric_diff_counted left right ~on_compare ~init
              ~f:(fun acc key -> function
                | Map.Left value -> emit acc key (Signal.Package.Left value)
                | Map.Right value ->
                    emit acc key (Signal.Package.Right value)
                | Map.Changed (old_value, new_value) ->
                    emit acc key
                      (Signal.Package.Changed (old_value, new_value))));
        }
      in
      let output_ops : (_, _, _) Signal.Package.output_ops =
        { Signal.Package.empty = M.empty; set = M.set; remove = M.remove }
      in
      Signal.Package.install
        (Signal.Package.stable_family ?data_cutoff ~input ~input_ops
           ~output_ops ~build:f ())

    module Testing = struct
      type token = Signal.Extension.token
      type entry_identity = Signal.Extension.keyed_entry_identity

      type event = Signal.Extension.keyed_event =
        | Detached of token
        | Invalidated of token
        | Attached of token

      type counter = Signal.Extension.keyed_counter =
        | Reconciliation_count
        | Input_key_comparison_count
        | Input_diff_event_count
        | Child_visit_count
        | Provisional_addition_count
        | Committed_addition_count
        | Committed_removal_count
        | Reconciliation_rollback_count

      type atomic_fault = Signal.Extension.atomic_fault

      type work_class = Signal.Extension.work_class =
        | Sources
        | Scheduler
        | Observer_delivery
        | Timer_reconciliation
        | Cleanup

      let work_count = Signal.Extension.work_count

      let entry_identity = Signal.Extension.keyed_entry_identity
      let scope_valid = Signal.Extension.keyed_scope_valid
      let pending = Signal.Extension.keyed_pending
      let set_preflight = Signal.Extension.set_keyed_preflight
      let set_atomic_fault = Signal.Extension.set_atomic_pass_fault
      let signal_token = Signal.Extension.signal_token
      let signal_valid_token = Signal.Extension.signal_valid_token
      let signal_demand_token = Signal.Extension.signal_demand_token

      let dependent_edge_count_token =
        Signal.Extension.dependent_edge_count_token

      let topology_counter_snapshot =
        Signal.Extension.topology_counter_snapshot

      let reset_counters = Signal.Extension.reset_counters

      let has_dependent_edge_token =
        Signal.Extension.has_dependent_edge_token

      let set_event_recorder = Signal.Extension.set_keyed_event_recorder
      let set_counter = Signal.Extension.set_keyed_counter
    end
  end
end
