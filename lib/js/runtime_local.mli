type 'a key
type table

val create : unit -> 'a key
val id : 'a key -> int
val create_table : unit -> table
val copy_table : table -> table
val get : table -> 'a key -> 'a option
val set : table -> 'a key -> 'a -> unit
val remove : table -> 'a key -> unit
val with_binding : table -> 'a key -> 'a -> (unit -> 'b) -> 'b
