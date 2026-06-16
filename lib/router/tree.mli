(** Radix tree used for route storage and lookup. *)

type 'a t

val empty : unit -> 'a t
(** [empty ()] creates a fresh empty tree. *)

val insert : 'a t -> Escape.t -> 'a -> (unit, Router_error.insert) result
(** [insert tree route value] registers [value] under [route].

    The route is unescaped but not yet normalized; [insert] normalizes
    parameter names internally. *)

val at : 'a t -> Slice.t -> ('a * Params.t, Router_error.match_) result
(** [at tree path] looks up [path] and returns the stored value and params. *)

val at_string : 'a t -> string -> ('a * Params.t, Router_error.match_) result
(** [at_string tree path] is like {!at} but accepts a raw string path. Used
    internally to avoid an intermediate slice allocation on lookup. *)

val compress : 'a t -> unit
(** [compress tree] merges consecutive single-child static nodes to reduce
    lookup depth. Safe to call after all inserts are complete. *)

val remove : 'a t -> Escape.t -> 'a option
(** [remove tree route] removes [route] from [tree] and returns its value.

    The route is unescaped but not yet normalized; [remove] normalizes
    parameter names internally and requires an exact parameter-name match. *)

val merge : into:'a t -> 'a t -> (unit, Router_error.merge) result
(** [merge ~into from] inserts every route from [from] into [into]. *)
