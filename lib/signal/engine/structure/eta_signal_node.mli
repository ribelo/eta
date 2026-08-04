type t

val create : unit -> t
val is_live : t -> bool
val invalidate : t -> bool
(** Change [Live] to [Invalid]. Return [false] after the first transition. *)
