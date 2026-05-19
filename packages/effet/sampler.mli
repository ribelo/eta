type t = {
  sample :
    trace_id:string ->
    name:string ->
    attrs:(string * string) list ->
    parent:bool ->
    bool;
}

val always_on : t
val always_off : t
val ratio : float -> t
val parent_based : ?root:t -> unit -> t
