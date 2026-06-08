type cause : value mod portable =
  | Fail of string
  | Die of (unit -> string)

