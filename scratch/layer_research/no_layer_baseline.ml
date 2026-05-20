open Effet
open Services

let db_factory clock =
  Effect.acquire_release ~acquire:(open_db clock) ~release:close_db

let http_factory clock log =
  Effect.acquire_release ~acquire:(open_http clock log) ~release:stop_http

let program db http =
  Effect.sync "app" (fun _ -> (app_result db http, db, http))

let boot clock log =
  Effect.scoped
    (db_factory clock
    |> Effect.bind (fun db ->
           http_factory clock log |> Effect.bind (fun http -> program db http)))

let run () =
  let clock = make_clock () in
  let log = make_log () in
  let result, db, http = boot clock log |> run_empty |> ok in
  (result, db.db_closed, http.http_stopped, log_lines log)

module type LOCKED = sig
  val db_factory : clock -> (<  >, string, db) Effect.t
  val http_factory : clock -> log -> (<  >, string, http) Effect.t
  val boot : clock -> log -> (<  >, string, string * db * http) Effect.t
  val run : unit -> string * bool * bool * string list
end

module _ : LOCKED = struct
  let db_factory = db_factory
  let http_factory = http_factory
  let boot = boot
  let run = run
end
