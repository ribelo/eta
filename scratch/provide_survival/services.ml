open Effet

type db = {
  label : string;
  mutable closed : bool;
}

type audit = { mutable lines : string list }
type secret = { token : string }

let make_db label = { label; closed = false }
let close_db db = db.closed <- true
let query db sql = db.label ^ ":" ^ sql

let audit () = { lines = [] }
let record audit line = audit.lines <- line :: audit.lines
let lines audit = List.rev audit.lines

let scoped_db label =
  Effect.acquire_release
    ~acquire:(Effect.sync "db.open" (fun _ -> make_db label))
    ~release:(fun db -> Effect.sync "db.close" (fun _ -> close_db db))

let query_from_env sql : (< db : db; .. >, 'err, string) Effect.t =
  Effect.sync "db.query" (fun env -> query env#db sql)

let audit_from_env line : (< audit : audit; .. >, 'err, unit) Effect.t =
  Effect.sync "audit.record" (fun env -> record env#audit line)

let secret_from_env () : (< secret : secret; .. >, 'err, string) Effect.t =
  Effect.sync "secret.read" (fun env -> env#secret.token)

let run eff env =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env () in
  Runtime.run rt eff

let ok = function
  | Exit.Ok value -> value
  | Exit.Error cause ->
      failwith
        (Format.asprintf "unexpected error: %a"
           (Cause.pp Format.pp_print_string)
           cause)
