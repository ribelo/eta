type err = [ `Db_down ] [@@deriving eta_error]

let () = Format.printf "tag=%a@." pp_err `Db_down
