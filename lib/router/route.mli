(** Route parsing and parameter normalization.

    Routes may contain named parameters ([/{id}]), catch-all parameters
    ([/{*path}]), prefix/suffix parameter patterns ([/images/img-{id}.png]),
    and escaped braces ([/{{static}}]). This module turns a raw route string
    into a normalized form suitable for storage in the radix tree. *)

type wildcard = {
  start : int;
      (** Inclusive index of the opening [{]. *)
  end_ : int;
      (** Exclusive index just past the closing [}]. *)
}

type remapping = string list
(** For each normalized parameter [{a}], [{b}], etc., the original parameter
    name in route order. Catch-all parameters are not normalized and do not
    appear in the remapping. *)

val find_wildcard : Escape.slice -> (wildcard option, Router_error.insert) result
(** [find_wildcard route] finds the first wildcard segment in [route].

    Returns an error for malformed routes such as unmatched braces, empty
    parameter names, or invalid characters inside parameter names. *)

val normalize : Escape.t -> (Escape.t * remapping, Router_error.insert) result
(** [normalize route] replaces every named parameter name with [{a}], [{b}],
    etc., while preserving catch-all parameters. Returns the normalized route
    and the remapping that allows original names to be restored. *)

val denormalize : Escape.t -> remapping -> Escape.t
(** [denormalize route remapping] restores the original parameter names in a
    normalized route. *)
