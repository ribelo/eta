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

module Make_package (Package : PACKAGE) = struct
  module Keyed (Order : Map.Ordered_type) = Keyed_adapter (Package) (Order)
end
