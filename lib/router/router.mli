(** Mutable radix-trie URL path router. *)

type 'a t

val create : unit -> 'a t
(** [create ()] returns a new empty router. *)

val insert : 'a t -> string -> 'a -> (unit, Router_error.insert) result
(** [insert router route value] registers [value] under [route]. *)

val at : 'a t -> string -> ('a Match.t, Router_error.match_) result
(** [at router path] looks up [path] and returns the matched value and params. *)

val find : 'a t -> string -> 'a option
(** [find router path] returns the matched value only, or [None]. *)

val remove : 'a t -> string -> 'a option
(** [remove router route] unregisters [route] and returns the stored value. *)

val merge : into:'a t -> 'a t -> (unit, Router_error.merge) result
(** [merge ~into from] inserts all routes from [from] into [into]. *)

val compress : 'a t -> unit
(** [compress router] merges consecutive single-child static nodes to reduce
    lookup depth. Safe to call after all inserts are complete; do not call
    before further inserts. *)
