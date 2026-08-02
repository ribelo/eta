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

module Make (Observer_error : Eta_signal.Observer_error) () : sig
  include module type of Eta_signal.Make (Observer_error) ()

  module Keyed (Order : Map.Ordered_type) : sig
    val mapi :
      ?data_cutoff:(published:'data -> candidate:'data -> bool) ->
      'data Map.Make(Order).t signal ->
      f:(key:Order.t -> data:'data signal -> 'output signal) ->
      'output Map.Make(Order).t signal
    (** Creates one stable child for each present key. The builder receives the
        stored key and one stable data signal. It runs only for provisional
        additions. [smkey-9b8i] [smkey-445b]

        Continuous presence preserves the key representative, keyed scope, data
        source, data signal, child signal, dependency edge, and child state.
        Accepted data is visible to the existing child in the same stabilization.
        [smkey-69cw] [smkey-2vhe]

        Removal invalidates that child incarnation. Later re-entry creates a
        fresh incarnation. Writes before stabilization reconcile only their final
        input snapshot. [smkey-d7oa] [smkey-vb62] [smkey-fu6q]

        Each key gets a distinct child cell. Reuse inside one keyed scope shares
        that scope's child cell. [smkey-l98z] [smkey-pqom]

        The optional cutoff applies only to retained physical data changes. Its
        default is physical identity. A [true] result keeps the published data.
        A [false] result publishes the candidate through the existing source.
        [smkey-c4jn] [smkey-xj6g] [smkey-jdgk] [smkey-4ddk]

        Cutoff arguments are [~published] then [~candidate]. A suppressed update
        keeps the published baseline for the next call. A raised exception rolls
        back the plan and a later stabilization can retry it. [smkey-z4eu]
        [smkey-8g9u] [smkey-b4zb]

        Additions, removals, and changed child outputs patch the previous output
        map. Each child signal supplies the only output cutoff. No output change
        preserves the output-map root. [smkey-mm6e] [smkey-6vtj] [smkey-j9v0]
        [smkey-bkjn] [smkey-gz8v]

        Mutation of one retained physical data object is not observable.
        [smkey-x2z7]

        Planning and structural preflight finish before commit. Commit removes
        and invalidates old children before it attaches additions. Failure keeps
        committed identities, values, and output roots. [smtxn-j5oi]
        [smtxn-b12v] [smtxn-78q6] [smtxn-7vp7] [smtxn-5rpo]
        [smtxn-00no]

        A successful transaction publishes one final output and one observer
        event. Completion leaves no pending keyed transaction work. [smtxn-oqx5]
        [smtxn-lrob] [smtxn-34ol] *)
  end
end
