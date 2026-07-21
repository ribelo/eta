type payload = { code : int }

type err = [ `Custom of payload ] [@@deriving eta_error]
