type payload = { id : string }

let pp_payload fmt payload = Format.pp_print_string fmt payload.id

type err =
  [ `Custom of payload [@eta.render pp_payload] ]
[@@deriving eta_error]
