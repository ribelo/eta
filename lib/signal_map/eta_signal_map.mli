(** Persistent keyed collections for Eta Signal. *)

module Map : sig
  module type Ordered_type = sig
    type t

    val compare : t -> t -> int
    (** A zero result defines key identity. The comparison must define a stable
        total order. A stored key must not mutate its order. [smmap-91wp]
        [smmap-zdxg] *)
  end

  type 'a change =
    | Left of 'a
        (** Data present only in the first map. *)
    | Right of 'a
        (** Data present only in the second map. *)
    | Changed of 'a * 'a
        (** First-map data and second-map data that are not physically equal. *)

  module type S = sig
    type key
    type 'a t
    (** An immutable map snapshot. Persistent edits preserve earlier snapshots
        and retain unchanged subtrees. [smmap-2sy9] [smmap-inyq] *)

    val empty : 'a t
    (** Contains no binding or tree ancestry. [smmap-eg8v] *)

    val singleton : key -> 'a -> 'a t
    (** Creates one fresh tree node. [smmap-4sla] [smdiff-91zh] *)

    val of_list :
      (key * 'a) list -> ('a t, [ `Duplicate_key of key ]) result
    (** Rejects the first duplicate in input order. The error contains the exact
        key from that duplicate occurrence. The function returns no partial map.
        A successful nonempty call creates fresh ancestry. [smmap-dq75]
        [smmap-cffd] [smmap-ikdi] [smdiff-91zh] *)

    val is_empty : 'a t -> bool
    val cardinal : 'a t -> int
    val mem : key -> 'a t -> bool
    val find_opt : key -> 'a t -> 'a option

    val set : key -> 'a -> 'a t -> 'a t
    (** Retains the stored key representative when the supplied key compares
        equal. A physical data no-op returns the same root. [smmap-bxwh]
        [smmap-nn25] [smmap-hht7] *)

    val remove : key -> 'a t -> 'a t
    (** Returns the same root when the key is absent. A later insertion after a
        removal uses the new supplied representative. [smmap-8a76] [smmap-e4r1]
        [smmap-hht7] *)

    val update : key -> ('a option -> 'a option) -> 'a t -> 'a t
    (** Applies insertion, replacement, removal, or absence from the returned
        option. A physical no-op returns the same root. [smmap-z7kg]
        [smmap-hht7] *)

    val fold : (key -> 'a -> 'acc -> 'acc) -> 'a t -> 'acc -> 'acc
    (** Visits each binding once in increasing key order. [smmap-qm48] *)

    val to_list : 'a t -> (key * 'a) list
    (** Returns each binding once in increasing key order. Rebuilding the list
        with {!of_list} starts fresh ancestry. [smmap-b81w] [smdiff-91zh] *)

    val map : ('a -> 'b) -> 'a t -> 'b t
    (** Preserves keys and applies the function once to each data value. It
        retains a node when its new data and children stay physically unchanged.
        A complete physical no-op returns the same root. [smmap-i14t]
        [smmap-86dk] [smmap-2yd7] *)

    val filter_mapi : (key -> 'a -> 'b option) -> 'a t -> 'b t
    (** Applies the function once to each binding and keeps returned values. It
        retains a node when its key, new data, and children stay physically
        unchanged. A complete physical no-op returns the same root. [smmap-g2tz]
        [smmap-86dk] [smmap-2yd7] *)

    val equal : ('a -> 'a -> bool) -> 'a t -> 'a t -> bool
    (** Extensional equality modulo key identity. An accepting predicate runs
        once for every aligned pair, including physically shared subtrees.
        Predicate order is unspecified. No predicate call occurs after the first
        rejection. [smmap-tz92] [smmap-aouh] [smmap-ge5r] *)

    val fold_symmetric_diff :
      'a t ->
      'a t ->
      init:'acc ->
      f:('acc -> key -> 'a change -> 'acc) ->
      'acc
    (** Emits one event per changed key in increasing key order. [Left] and
        [Changed] use the first-map representative. [Right] uses the second-map
        representative.

        Physical identity is the complete aligned-data boundary. A shared data
        object emits no event. Distinct objects emit [Changed], even when their
        fields are equal. The function accepts no data-equality predicate.
        [smdiff-ij95] [smdiff-uoix] [smdiff-mwo3] [smdiff-8cdy]
        [smdiff-zuwx] [smdiff-yhgb] [smdiff-g1jq]

        Applying the events to the first map reconstructs the second map.
        Reversing the events reconstructs the first map from the second map.
        [smdiff-5d9x] [smdiff-4nzq] *)
  end

  module Make (Order : Ordered_type) : S with type key = Order.t
  (** Two applications to the same stable module path produce compatible map
      types. Different module paths produce incompatible types. [smmap-e04b]
      [smmap-4d3u] *)
end
