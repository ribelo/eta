type err =
  [ `Db of int
  | `Unavailable ]
[@@deriving eta_error]
