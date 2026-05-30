type t = Connection.t

let begin_transaction conn =
  match Connection.begin_transaction conn with
  | Ok () -> Ok conn
  | Result.Error _ as err -> err

let commit = Connection.commit
let rollback = Connection.rollback
let with_transaction = Connection.with_transaction
