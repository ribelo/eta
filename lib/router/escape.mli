(** Unescaped route strings with escaped-brace metadata.

    Literal [{] and [}] in a route are escaped by doubling them ([{{], [}}]).
    This module tracks the unescaped bytes together with which positions were
    originally escaped, so wildcard detection does not mistake an escaped brace
    for a parameter marker. *)

module Int_set : Set.S with type elt = int

type t = private {
  bytes : string;
  escaped : string;
}
(** An owned, unescaped route.

    The [escaped] field stores one byte per position in [bytes]: ['\001']
    means the byte came from an escaped brace, ['\000'] means it did not. *)

type slice = private {
  src : t;
  off : int;
  len : int;
}
(** A non-owning slice into an unescaped route. *)

val of_string : string -> t
(** [of_string s] unescapes doubled braces and records escaped positions. *)

val of_unescaped : string -> Int_set.t -> t
(** [of_unescaped s escaped] constructs a route from already-unescaped bytes.
    The caller is responsible for ensuring [s] really contains no doubled braces. *)

val make_unescaped : bytes:string -> escaped:string -> t
(** [make_unescaped ~bytes ~escaped] constructs a route directly from its
    internal representation. [escaped] must contain only ['\000'] or ['\001']
    bytes, one per byte in [bytes]. *)

val to_string : t -> string
(** [to_string r] returns the unescaped bytes. *)

val length : t -> int
(** [length r] is the number of bytes in [r]. *)

val get : t -> int -> char
(** [get r i] is the [i]-th byte.

    @raise Invalid_argument if [i] is out of bounds. *)

val unsafe_get : t -> int -> char
(** [unsafe_get r i] is the [i]-th byte without bounds checking.

    Undefined behavior if [i] is out of bounds. *)

val is_escaped : t -> int -> bool
(** [is_escaped r i] is [true] iff the byte at [i] came from an escaped brace. *)

val full : t -> slice
(** [full r] is a slice covering the whole route. *)

val slice : slice -> off:int -> len:int -> slice
(** [slice s ~off ~len] is the sub-slice starting at [off] with length [len].

    @raise Invalid_argument if the sub-slice is out of bounds. *)

val slice_off : slice -> int -> slice
(** [slice_off s n] drops the first [n] bytes.

    @raise Invalid_argument if [n] exceeds [length s]. *)

val slice_until : slice -> int -> slice
(** [slice_until s n] keeps the first [n] bytes.

    @raise Invalid_argument if [n] exceeds [length s]. *)

val slice_length : slice -> int
(** [slice_length s] is the length of the slice in bytes. *)

val slice_get : slice -> int -> char
(** [slice_get s i] is the [i]-th byte of the slice.

    @raise Invalid_argument if [i] is out of bounds. *)

val slice_unsafe_get : slice -> int -> char
(** [slice_unsafe_get s i] is the [i]-th byte of the slice without a bounds
    check. *)

val slice_is_escaped : slice -> int -> bool
(** [slice_is_escaped s i] is [true] iff position [i] within the slice is escaped. *)

val slice_to_string : slice -> string
(** [slice_to_string s] copies the slice into a fresh string. *)

val slice_to_owned : slice -> t
(** [slice_to_owned s] copies the slice into a fresh owned route. *)

val common_prefix : slice -> slice -> int
(** [common_prefix a b] returns the length of the longest shared prefix,
    considering both bytes and escape status. *)

val append : t -> t -> t
(** [append a b] concatenates two unescaped routes, preserving escaped brace
    metadata. *)
