(* R-B: 'env channel as object row. The Effect-TS R-channel idiom.
   This is what V3 / V-R1 picked. We are testing whether it actually
   gives auto-DI: A defined without mentioning services or threading. *)

module Effect = struct
  type ('env, 'err, 'a) t =
    | Pure : 'a -> (_, _, 'a) t
    | Sync : ('env -> 'a) -> ('env, _, 'a) t
    | Bind : ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t) -> ('env, 'err, 'a) t
    | Fail : 'err -> (_, 'err, _) t

  let pure v = Pure v
  let sync f = Sync f
  let bind k e = Bind (e, k)
  let ( let* ) e k = Bind (e, k)

  let rec run : type env err a.
      env -> (env, err, a) t -> (a, err) result =
   fun env -> function
    | Pure v -> Ok v
    | Sync f -> Ok (f env)
    | Fail e -> Error e
    | Bind (e, k) -> (match run env e with Ok v -> run env (k v) | Error e -> Error e)
end

open Services

(* Helpers READ from env. They do not take services as args. *)
let c id : (< db : db; .. >, [> `Db_err ], string) Effect.t =
  Effect.sync (fun env -> env#db#query id)

let b msg : (< log : log; .. >, _, unit) Effect.t =
  Effect.sync (fun env -> env#log#info msg)

(* THE TEST: A defined without args, without naming services. *)
let a id =
  let open Effect in
  let* () = b (Printf.sprintf "fetching %s" id) in
  c id

(* Boot. *)
let boot () =
  let env =
    object
      method db = db_of (Db.make "main")
      method log = log_of (Log.make "[info] ")
    end
  in
  Effect.run env (a "42")

(* === Auto-DI assertion ===
   A's inferred type unions B's <log> and C's <db> automatically.
   A's BODY did not mention services or threading. *)

module type A_SIG = sig
  val a :
    string ->
    (< db : db; log : log; .. >, [> `Db_err ], string) Effect.t
end

module _ : A_SIG = struct let a = a end

(* What forgetting a service looks like at boot: *)
(* Uncomment to verify the missing-method error:

let bad_boot () =
  let env = object method db = db_of (Db.make "x") end in
  Effect.run env (a "42")
*)
