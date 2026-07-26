open Reader_port

let configured_second db =
  let open Reader.Syntax in
  let* selected = Reader_port.users in
  Reader_port.lookup db selected.second

let program_with_override =
  let open Reader.Syntax in
  with_user_db @@ fun db ->
  let* selected = Reader_port.users in
  let* first = lookup db selected.first in
  let+ second =
    Reader.local
      (fun env ->
        { env with users = { env.users with second = "carol" } })
      (configured_second db)
  in
  (first, second)
