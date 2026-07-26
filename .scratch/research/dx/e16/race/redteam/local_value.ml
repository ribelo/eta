open Eta
open Value_passing

let program_with_override clock released users =
  let open Syntax in
  let@ db = with_user_db clock released in
  let* first = User_db.lookup db users.first in
  let overridden_users = { users with second = "carol" } in
  let+ second = User_db.lookup db overridden_users.second in
  (first, second)
