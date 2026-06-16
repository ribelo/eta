(** Matched route parameters.

    Parameters are stored as zero-copy slices into the matched path and copied
    only when retrieved through {!get}, {!to_list}, etc. *)

type t

val empty : t
(** The empty parameter set. *)

val is_empty : t -> bool
(** [is_empty params] is [true] when no parameters are present. *)

val get : t -> string -> string option
(** [get params name] returns the value of parameter [name], if present. *)

val mem : t -> string -> bool
(** [mem params name] is [true] iff [name] is bound in [params]. *)

val to_list : t -> (string * string) list
(** [to_list params] returns all parameters as name-value pairs. *)

val iter : (string -> string -> unit) -> t -> unit
(** [iter f params] applies [f name value] to each parameter. *)

val fold : (string -> string -> 'acc -> 'acc) -> t -> 'acc -> 'acc
(** [fold f params acc] folds over each parameter. *)

val of_list : (string * Slice.t) list -> t
(** [of_list params] constructs a parameter set from name-slice pairs. *)

val of_offsets : (string * string * int * int) list -> t
(** [of_offsets params] constructs a parameter set from name-path-offset
    tuples. Used internally by the router to avoid intermediate slice
    allocations. *)

val of_raw :
  params:(string * int * int) list ->
  remapping:string list ->
  catch_all:(string * string * int * int) option ->
  t
(** [of_raw ~params ~remapping ~catch_all] constructs a lazy parameter set
    from raw path-offset tuples. Parameters are named only on demand, avoiding
    allocation for callers that discard the parameter set. *)
