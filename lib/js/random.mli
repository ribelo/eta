(** Deterministic generators over {!Capabilities.random}.

    [Capabilities.random] is a mutable runtime token rather than an object
    capability. Pass explicit random tokens into runtime-owned scheduling or
    application helpers instead of closing over object methods. *)

val int_in_range : Capabilities.random -> min:int -> max:int -> int
(** [int_in_range random ~min:1 ~max:6] draws an integer in the inclusive
    range [[1, 6]]. *)

val float_in_range : Capabilities.random -> min:float -> max:float -> float
(** [float_in_range random ~min:0.0 ~max:1.0] draws a float in
    [[0.0, 1.0)]. *)

val bool : Capabilities.random -> bool
(** [bool random] draws [true] or [false]. *)

val shuffle : Capabilities.random -> 'a list -> 'a list
(** [shuffle random items] returns a deterministically shuffled copy of
    [items]. *)

val weighted_choice : Capabilities.random -> ('a * float) list -> 'a option
(** [weighted_choice random choices] draws one value, ignoring nonpositive
    weights. *)

val sample : Capabilities.random -> 'a list -> 'a option
(** [sample random items] draws one item, or [None] for an empty list. *)
