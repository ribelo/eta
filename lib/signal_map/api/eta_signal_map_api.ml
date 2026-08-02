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

module Make (Observer_error : Eta_signal.Observer_error) () = struct
  module Signal = Eta_signal_kernel.Make (Observer_error) ()
  include Signal

  module Keyed (Order : Map.Ordered_type) = struct
    module M = Map.Make (Order)
    module Kernel_map = Eta_signal_map_kernel.Make (Order)

    let map_ops () : (_, _, _) Signal.Extension.keyed_map_ops =
      {
        Signal.keyed_empty = M.empty;
        keyed_find_opt = M.find_opt;
        keyed_set = M.set;
        keyed_remove = M.remove;
        keyed_fold = M.fold;
      }

    let mapi ?data_cutoff input ~f =
      let data_map = map_ops () in
      let data_ops : (_, _, _) Signal.Extension.keyed_diff_ops =
        {
          Signal.keyed_map = data_map;
          keyed_fold_diff =
            (fun left right ~on_compare ~init ~f ->
            Kernel_map.fold_symmetric_diff_counted left right ~on_compare ~init
              ~f:(fun acc key -> function
                | Map.Left value ->
                    f acc key (Signal.Extension.Keyed_left value)
                | Map.Right value ->
                    f acc key (Signal.Extension.Keyed_right value)
                | Map.Changed (old_value, new_value) ->
                    f acc key
                      (Signal.Extension.Keyed_changed (old_value, new_value))));
        }
      in
      Signal.Extension.keyed_mapi ?data_cutoff ~data_ops
        ~child_ops:(map_ops ()) ~output_ops:(map_ops ()) input ~f

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

      let entry_identity = Signal.Extension.keyed_entry_identity
      let scope_valid = Signal.Extension.keyed_scope_valid
      let pending = Signal.Extension.keyed_pending
      let set_preflight = Signal.Extension.set_keyed_preflight
      let set_event_recorder = Signal.Extension.set_keyed_event_recorder
      let set_counter = Signal.Extension.set_keyed_counter
    end
  end
end
