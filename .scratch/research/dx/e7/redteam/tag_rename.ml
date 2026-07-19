type err = [ `Database_down ] [@@deriving eta_error]

let () = Format.printf "tag=%a@." pp_err `Database_down
