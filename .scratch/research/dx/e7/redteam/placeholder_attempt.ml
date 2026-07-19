type payload = { id : string }

type err = [ `Custom of payload ] [@@deriving eta_error]
