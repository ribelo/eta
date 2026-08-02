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
