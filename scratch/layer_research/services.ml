open Effet

type clock = { mutable ticks : int }
type log = { mutable lines : string list }

type db = {
  db_label : string;
  db_opened_at : int;
  mutable db_closed : bool;
}

type http = {
  http_label : string;
  http_opened_at : int;
  mutable http_stopped : bool;
}

let make_clock () = { ticks = 0 }
let now clock = clock.ticks <- clock.ticks + 1; clock.ticks

let make_log () = { lines = [] }
let record log line = log.lines <- line :: log.lines
let log_lines log = List.rev log.lines

let open_db clock =
  Effect.sync "db.open" (fun _ ->
      { db_label = "db"; db_opened_at = now clock; db_closed = false })

let close_db db =
  Effect.sync "db.close" (fun _ -> db.db_closed <- true)

let query db sql =
  Printf.sprintf "%s:%s@%d" db.db_label sql db.db_opened_at

let open_http clock log =
  Effect.sync "http.open" (fun _ ->
      let opened_at = now clock in
      record log (Printf.sprintf "http-open@%d" opened_at);
      { http_label = "http"; http_opened_at = opened_at; http_stopped = false })

let stop_http http =
  Effect.sync "http.stop" (fun _ -> http.http_stopped <- true)

let request http path =
  Printf.sprintf "%s:%s@%d" http.http_label path http.http_opened_at

let app_result db http =
  query db "select" ^ "|" ^ request http "/health"

let run_with_env env eff =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env () in
  Runtime.run rt eff

let run_empty eff = run_with_env (object end) eff

let ok = function
  | Exit.Ok value -> value
  | Exit.Error cause ->
      failwith
        (Format.asprintf "unexpected error: %a"
           (Cause.pp Format.pp_print_string)
           cause)

let expected_result = "db:select@1|http:/health@2"
