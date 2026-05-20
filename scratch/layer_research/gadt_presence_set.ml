open Effet
open Services

module Env = struct
  type _ cap =
    | Clock : clock cap
    | Log : log cap
    | Db : db cap
    | Http : http cap

  type _ t =
    | Nil : unit t
    | Cons : 'a cap * 'a * 'rest t -> ('a * 'rest) t

  type (_, _) has =
    | Here : ('a * 'rest, 'a) has
    | There : ('rest, 'a) has -> ('b * 'rest, 'a) has

  let empty = Nil
  let cons cap value rest = Cons (cap, value, rest)

  let rec get : type set a. (set, a) has -> set t -> a =
   fun witness env ->
    match (witness, env) with
    | Here, Cons (_, value, _) -> value
    | There witness, Cons (_, _, rest) -> get witness rest
end

module Layer = struct
  type ('need, 'provide, 'err) t =
    'need Env.t -> (<  >, 'err, 'provide Env.t) Effect.t

  let singleton cap acquire release env =
    Effect.acquire_release ~acquire:(acquire env) ~release
    |> Effect.map (fun value -> Env.cons cap value Env.empty)

  let merge left right env =
    left env
    |> Effect.bind (function
         | Env.Cons (left_cap, left_value, Env.Nil) ->
             right env
             |> Effect.map (function
                  | Env.Cons (right_cap, right_value, Env.Nil) ->
                      Env.cons left_cap left_value
                        (Env.cons right_cap right_value Env.empty)))

  let use env layer f = Effect.scoped (layer env |> Effect.bind f)
end

let db_layer : (clock * 'rest, db * unit, string) Layer.t =
 fun env ->
  let clock = Env.get Env.Here env in
  Layer.singleton Env.Db (fun _ -> open_db clock) close_db env

let http_layer : (clock * (log * 'rest), http * unit, string) Layer.t =
 fun env ->
  let clock = Env.get Env.Here env in
  let log = Env.get (Env.There Env.Here) env in
  Layer.singleton Env.Http (fun _ -> open_http clock log) stop_http env

let app_layer : (clock * (log * 'rest), db * (http * unit), string) Layer.t =
 fun env -> Layer.merge db_layer http_layer env

let duplicate_db_layer : (clock * 'rest, db * (db * unit), string) Layer.t =
 fun env -> Layer.merge db_layer db_layer env

let app_program services =
  let db = Env.get Env.Here services in
  let http = Env.get (Env.There Env.Here) services in
  Effect.sync "app" (fun _ -> (app_result db http, db, http))

let boot_env clock log =
  Env.cons Env.Clock clock (Env.cons Env.Log log Env.empty)

let run () =
  let clock = make_clock () in
  let log = make_log () in
  let result, db, http =
    Layer.use (boot_env clock log) app_layer app_program |> run_empty |> ok
  in
  (result, db.db_closed, http.http_stopped, log_lines log)

module type LOCKED = sig
  type 'a env
  type ('need, 'provide, 'err) layer

  val db_layer : (clock * 'rest, db * unit, string) layer

  val http_layer :
    (clock * (log * 'rest), http * unit, string) layer

  val app_layer :
    (clock * (log * 'rest), db * (http * unit), string) layer

  val duplicate_db_layer : (clock * 'rest, db * (db * unit), string) layer

  val boot_env : clock -> log -> (clock * (log * unit)) env
  val run : unit -> string * bool * bool * string list
end

module _ :
  LOCKED
    with type 'a env = 'a Env.t
     and type ('need, 'provide, 'err) layer = ('need, 'provide, 'err) Layer.t =
struct
  type 'a env = 'a Env.t
  type ('need, 'provide, 'err) layer = ('need, 'provide, 'err) Layer.t

  let db_layer = db_layer
  let http_layer = http_layer
  let app_layer = app_layer
  let duplicate_db_layer = duplicate_db_layer
  let boot_env = boot_env
  let run = run
end
