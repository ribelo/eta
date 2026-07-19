type err =
  [ `Not_found of string
  | `Db of int
  | `Unavailable ]
[@@deriving eta_error]
