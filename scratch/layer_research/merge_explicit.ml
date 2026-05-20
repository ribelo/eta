open Effet
open Services

module Layer = struct
  type ('rin, 'err, 'out) t = ('rin, 'err, 'out) Effect.t

  let scoped ~acquire ~release =
    Effect.acquire_release ~acquire ~release

  let merge ~combine left right =
    left
    |> Effect.bind (fun left_value ->
           right |> Effect.map (fun right_value -> combine left_value right_value))

  let use layer f = Effect.scoped (layer |> Effect.bind f)
end

let db_layer () : (< clock : clock; .. >, string, db) Layer.t =
  Layer.scoped
    ~acquire:(Effect.sync "db.clock" (fun env -> env#clock) |> Effect.bind open_db)
    ~release:close_db

let http_layer () : (< clock : clock; log : log; .. >, string, http) Layer.t =
  Layer.scoped
    ~acquire:
      (Effect.sync "http.deps" (fun env -> (env#clock, env#log))
      |> Effect.bind (fun (clock, log) -> open_http clock log))
    ~release:stop_http

let app_layer ()
    : (< clock : clock; log : log; .. >, string, < db : db; http : http >) Layer.t
    =
  Layer.merge (db_layer ()) (http_layer ())
    ~combine:(fun db http ->
      object
        method db = db
        method http = http
      end)

let app_program services =
  Effect.sync "app" (fun _ -> (app_result services#db services#http, services#db, services#http))

let run () =
  let clock = make_clock () in
  let log = make_log () in
  let env =
    object
      method clock = clock
      method log = log
    end
  in
  let result, db, http = run_with_env env (Layer.use (app_layer ()) app_program) |> ok in
  (result, db.db_closed, http.http_stopped, log_lines log)

module type LOCKED = sig
  val db_layer : unit -> (< clock : clock; .. >, string, db) Effect.t

  val http_layer :
    unit ->
    (< clock : clock; log : log; .. >, string, http) Effect.t

  val app_layer :
    unit ->
    (< clock : clock; log : log; .. >, string, < db : db; http : http >) Effect.t

  val run : unit -> string * bool * bool * string list
end

module _ : LOCKED = struct
  let db_layer = db_layer
  let http_layer = http_layer
  let app_layer = app_layer
  let run = run
end
