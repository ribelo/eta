(* R-D: OCaml 5 native algebraic effects for service lookup.
   No 'env on the Effect.t. Services are retrieved via [perform].
   Handlers installed at boot. *)

module Effect_lib = struct
  type ('err, 'a) t =
    | Pure : 'a -> (_, 'a) t
    | Sync : (unit -> 'a) -> (_, 'a) t
    | Bind : ('err, 'b) t * ('b -> ('err, 'a) t) -> ('err, 'a) t
    | Fail : 'err -> ('err, _) t

  let pure v = Pure v
  let sync f = Sync f
  let bind k e = Bind (e, k)
  let ( let* ) e k = Bind (e, k)
  let rec run : type err a. (err, a) t -> (a, err) result = function
    | Pure v -> Ok v
    | Sync f -> Ok (f ())
    | Fail e -> Error e
    | Bind (e, k) -> (match run e with Ok v -> run (k v) | Error e -> Error e)
end

open Services

(* Native OCaml 5 effects to fetch services. *)
type _ Effect.t += Get_db  : Db.t  Effect.t
type _ Effect.t += Get_log : Log.t Effect.t

(* Helpers `perform` for the service. No service argument anywhere. *)
let c id : ([> `Db_err ], string) Effect_lib.t =
  Effect_lib.sync (fun () -> Db.query (Effect.perform Get_db) id)

let b msg : (_, unit) Effect_lib.t =
  Effect_lib.sync (fun () -> Log.info (Effect.perform Get_log) msg)

(* A: no args, no service mentions, no threading. *)
let a id =
  let open Effect_lib in
  let* () = b (Printf.sprintf "fetching %s" id) in
  c id

(* Boot: install handlers that supply services. *)
let boot () =
  let db = Db.make "main" in
  let log = Log.make "[info] " in
  let open Effect.Deep in
  try_with
    (fun () -> Effect_lib.run (a "42"))
    ()
    {
      effc =
        (fun (type c) (eff : c Effect.t) ->
          match eff with
          | Get_db ->
              Some
                (fun (k : (c, _) continuation) -> continue k db)
          | Get_log ->
              Some
                (fun (k : (c, _) continuation) -> continue k log)
          | _ -> None);
    }

(* === Auto-DI assertion ===
   A is defined without mentioning services. Inferred type does NOT
   show what services are required. *)

module type A_SIG = sig
  val a : string -> ([> `Db_err ], string) Effect_lib.t
end

module _ : A_SIG = struct let a = a end

(* CRITICAL CAVEAT: forgetting to install a handler is a RUNTIME
   crash (Effect.Unhandled), not a compile error. Demonstrate: *)

let unsafe_boot_no_handler () =
  (* This compiles fine. It will raise at runtime. *)
  Effect_lib.run (a "42")
