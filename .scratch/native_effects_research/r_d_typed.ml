open Services

type _ Effect.t +=
  | Get_db : Db.t Effect.t
  | Get_log : Log.t Effect.t

module Presence_set = struct
  type db_cap
  type log_cap
  type nil
  type ('cap, 'rest) cons = 'cap * 'rest

  type (_, _) has =
    | Here : (('cap, 'rest) cons, 'cap) has
    | There : ('rest, 'cap) has -> (('other, 'rest) cons, 'cap) has

  type (_, _) req =
    | Db : (db_cap, Db.t) req
    | Log : (log_cap, Log.t) req

  type _ handlers =
    | HNil : nil handlers
    | HDb : Db.t * 'rest handlers -> (db_cap, 'rest) cons handlers
    | HLog : Log.t * 'rest handlers -> (log_cap, 'rest) cons handlers

  type ('need, 'err, 'a) t =
    | Pure : 'a -> (_, _, 'a) t
    | Sync : (unit -> 'a) -> (_, _, 'a) t
    | Bind :
        ('need, 'err, 'b) t * ('b -> ('need, 'err, 'a) t)
        -> ('need, 'err, 'a) t
    | Fail : 'err -> (_, 'err, _) t

  let pure v = Pure v
  let sync f = Sync f
  let fail e = Fail e
  let ( let* ) e k = Bind (e, k)

  let ask :
      type need cap svc err.
      (need, cap) has -> (cap, svc) req -> (need, err, svc) t =
   fun _ req ->
    Sync
      (fun () ->
        match req with
        | Db -> Effect.perform Get_db
        | Log -> Effect.perform Get_log)

  let rec run_unhandled : type need err a. (need, err, a) t -> (a, err) result =
    function
    | Pure v -> Ok v
    | Sync f -> Ok (f ())
    | Fail e -> Error e
    | Bind (e, k) -> (
        match run_unhandled e with
        | Ok v -> run_unhandled (k v)
        | Error e -> Error e)

  let with_db (db : Db.t) f =
    let open Effect.Deep in
    try_with f ()
      {
        effc =
          (fun (type c) (eff : c Effect.t) ->
            match eff with
            | Get_db -> Some (fun (k : (c, _) continuation) -> continue k db)
            | _ -> None);
      }

  let with_log (log : Log.t) f =
    let open Effect.Deep in
    try_with f ()
      {
        effc =
          (fun (type c) (eff : c Effect.t) ->
            match eff with
            | Get_log -> Some (fun (k : (c, _) continuation) -> continue k log)
            | _ -> None);
      }

  let rec with_handlers : type need a. need handlers -> (unit -> a) -> a =
   fun handlers f ->
    match handlers with
    | HNil -> f ()
    | HDb (db, rest) -> with_db db (fun () -> with_handlers rest f)
    | HLog (log, rest) -> with_log log (fun () -> with_handlers rest f)

  let run : type need err a. need handlers -> (need, err, a) t -> (a, err) result =
   fun handlers program -> with_handlers handlers (fun () -> run_unhandled program)

  type both = (db_cap, (log_cap, nil) cons) cons

  let db_witness : (both, db_cap) has = Here
  let log_witness : (both, log_cap) has = There Here

  let c db_witness id : (both, [> `Db_err ], string) t =
    let* db = ask db_witness Db in
    pure (Db.query db id)

  let b log_witness msg : (both, _, unit) t =
    let* log = ask log_witness Log in
    pure (Log.info log msg)

  let a db_witness log_witness id =
    let* () = b log_witness (Printf.sprintf "fetching %s" id) in
    c db_witness id

  let boot () =
    let db = Db.make "main" in
    let log = Log.make "[info] " in
    run (HDb (db, HLog (log, HNil))) (a db_witness log_witness "42")

  module type A_SIG = sig
    type need

    val a :
      (need, db_cap) has ->
      (need, log_cap) has ->
      string ->
      (need, [> `Db_err ], string) t
  end

  module _ : A_SIG with type need = both = struct
    type need = both

    let a = a
  end
end

module Scoped_token = struct
  type db_token
  type log_token
  type _ token = Token : _ token

  type (_, _) req =
    | Db : (db_token, Db.t) req
    | Log : (log_token, Log.t) req

  type ('err, 'a) t =
    | Pure : 'a -> (_, 'a) t
    | Sync : (unit -> 'a) -> (_, 'a) t
    | Bind : ('err, 'b) t * ('b -> ('err, 'a) t) -> ('err, 'a) t
    | Fail : 'err -> ('err, _) t
    | With_db : Db.t * (db_token token -> ('err, 'a) t) -> ('err, 'a) t
    | With_log : Log.t * (log_token token -> ('err, 'a) t) -> ('err, 'a) t

  let pure v = Pure v
  let sync f = Sync f
  let fail e = Fail e
  let ( let* ) e k = Bind (e, k)

  let ask : type cap svc err. cap token -> (cap, svc) req -> (err, svc) t =
   fun _ req ->
    Sync
      (fun () ->
        match req with
        | Db -> Effect.perform Get_db
        | Log -> Effect.perform Get_log)

  let with_db db f = With_db (db, f)
  let with_log log f = With_log (log, f)

  let with_db_handler (db : Db.t) f =
    let open Effect.Deep in
    try_with f ()
      {
        effc =
          (fun (type c) (eff : c Effect.t) ->
            match eff with
            | Get_db -> Some (fun (k : (c, _) continuation) -> continue k db)
            | _ -> None);
      }

  let with_log_handler (log : Log.t) f =
    let open Effect.Deep in
    try_with f ()
      {
        effc =
          (fun (type c) (eff : c Effect.t) ->
            match eff with
            | Get_log -> Some (fun (k : (c, _) continuation) -> continue k log)
            | _ -> None);
      }

  let rec run : type err a. (err, a) t -> (a, err) result = function
    | Pure v -> Ok v
    | Sync f -> Ok (f ())
    | Fail e -> Error e
    | Bind (e, k) -> (
        match run e with Ok v -> run (k v) | Error e -> Error e)
    | With_db (db, f) -> with_db_handler db (fun () -> run (f Token))
    | With_log (log, f) -> with_log_handler log (fun () -> run (f Token))

  let c db_token id : ([> `Db_err ], string) t =
    let* db = ask db_token Db in
    pure (Db.query db id)

  let b log_token msg : (_, unit) t =
    let* log = ask log_token Log in
    pure (Log.info log msg)

  let a db_token log_token id =
    let* () = b log_token (Printf.sprintf "fetching %s" id) in
    c db_token id

  let boot () =
    let db = Db.make "main" in
    let log = Log.make "[info] " in
    run
      (with_db db (fun db_token ->
           with_log log (fun log_token -> a db_token log_token "42")))

  module type A_SIG = sig
    val a :
      db_token token ->
      log_token token ->
      string ->
      ([> `Db_err ], string) t
  end

  module _ : A_SIG = struct
    let a = a
  end
end
