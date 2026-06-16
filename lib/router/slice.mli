(** Zero-copy string slice used for route and path matching.

    Slices reference a substring of an immutable [string] without copying.
    They are the internal workhorse that lets the router compare paths and
    extract parameters without allocating. *)

type t = private {
  src : string;
  off : int;
  len : int;
}

val of_string : string -> t
(** [of_string s] is a slice covering all of [s]. *)

val of_string_sub : string -> int -> int -> t
(** [of_string_sub s off len] is a slice of [s] starting at [off] with length [len].

    @raise Invalid_argument if the slice is out of bounds. *)

val to_string : t -> string
(** [to_string s] copies the slice into a fresh string. *)

val length : t -> int
(** [length s] is the number of characters in the slice. *)

val is_empty : t -> bool
(** [is_empty s] is [true] iff [length s = 0]. *)

val get : t -> int -> char
(** [get s i] returns the [i]-th character of the slice.

    @raise Invalid_argument if [i] is out of bounds. *)

val unsafe_get : t -> int -> char
(** [unsafe_get s i] returns the [i]-th character without a bounds check. *)

val sub : t -> int -> int -> t
(** [sub s off len] is the sub-slice starting at [off] with length [len].

    @raise Invalid_argument if the sub-slice is out of bounds. *)

val drop : t -> int -> t
(** [drop s n] is [s] with the first [n] characters removed.

    @raise Invalid_argument if [n] exceeds [length s]. *)

val take : t -> int -> t
(** [take s n] is the first [n] characters of [s].

    @raise Invalid_argument if [n] exceeds [length s]. *)

val common_prefix : t -> t -> int
(** [common_prefix a b] returns the length of the longest shared prefix. *)
