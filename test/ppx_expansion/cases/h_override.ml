type payload = { code : int }

let pp_payload fmt payload = Format.fprintf fmt "payload(%d)" payload.code

type err =
  [ `Custom of payload [@eta.render pp_payload] ]
[@@deriving eta_error]
