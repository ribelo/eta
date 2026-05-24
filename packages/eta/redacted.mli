type 'a t = 'a Eta_redacted.t

val make : ?label:string -> 'a -> 'a t
val value : 'a t -> 'a
val wipe_unsafe : 'a t -> bool
(** [wipe_unsafe t] drops Eta's reference to the protected value and returns
    [true] if a value was present. It does not securely zero memory; immutable
    strings or other heap values may remain in memory until the OCaml runtime
    reclaims them. *)
val label : 'a t -> string option
val pp : Format.formatter -> 'a t -> unit
val equal : ('a -> 'a -> bool) -> 'a t -> 'a t -> bool
val hash : ('a -> int) -> 'a t -> int
