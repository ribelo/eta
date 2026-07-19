let pp_string fmt value = Format.fprintf fmt "quoted(%s)" value

type err =
  [ `Custom of string [@eta.render pp_string] ]
[@@deriving eta_error]
