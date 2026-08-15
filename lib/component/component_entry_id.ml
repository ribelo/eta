(* Application-owned stable entry identifiers.

   An entry identifier is one to one hundred twenty-eight ASCII letters,
   digits, [.]s, [_]s, or [-]s. Identity is the validated string itself;
   child position in a desired-state tree is structural data, not identity. *)

type t = string

let max_length = 128

let valid_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
  | _ -> false

let valid s =
  let length = String.length s in
  length > 0 && length <= max_length && String.for_all valid_char s

let of_string s = if valid s then Ok s else Error `Invalid_entry_id
let equal = String.equal
let compare = String.compare
let pp = Format.pp_print_string
let to_string t = t
