type t : immutable_data

val always_on : t
val always_off : t
val ratio : float -> t
val parent_based : ?root:t -> unit -> t
val sample :
  t ->
  trace_id:string ->
  name:string ->
  attrs:(string * string) list ->
  parent:bool ->
  bool
