type insert =
  | Conflict of string
  | Invalid_route of string

type match_ = Not_found
type merge = Conflicts of insert list
