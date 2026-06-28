open Effet

type db = { name : string }
type audit = { mutable entries : string list }
type secret = { token : string }
type clock = { now : int }
type log = { mutable lines : string list }
type metrics = { mutable count : int }

let db name = { name }
let audit () = { entries = [] }
let secret token = { token }
let clock now = { now }
let log () = { lines = [] }
let metrics () = { count = 0 }

let query db sql = db.name ^ ":" ^ sql

let write_audit audit line =
  audit.entries <- audit.entries @ [ line ]

let write_log log line =
  log.lines <- log.lines @ [ line ]

let record_metric metrics =
  metrics.count <- metrics.count + 1

let unwrap_exit = function
  | Exit.Ok value -> value
  | Exit.Error cause ->
      failwith (Format.asprintf "%a" (Cause.pp Format.pp_print_string) cause)

let run_with_env env effect_ =
  Eio_main.run @@ fun std ->
  Eio.Switch.run @@ fun sw ->
  let runtime =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock std) ~env ()
  in
  Runtime.run runtime effect_ |> unwrap_exit
