(* R-A explicit: services as labeled arguments. No 'env. *)

module Effect = struct
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

(* Each function mentions every service it transitively uses. *)
let c ~db id : ([> `Db_err ], string) Effect.t =
  Effect.sync (fun () -> Db.query db id)

let b ~log msg : (_, unit) Effect.t =
  Effect.sync (fun () -> Log.info log msg)

let a ~db ~log id =
  let open Effect in
  let* () = b ~log (Printf.sprintf "fetching %s" id) in
  c ~db id

(* Boot. *)
let boot () =
  let db = Db.make "main" in
  let log = Log.make "[info] " in
  Effect.run (a ~db ~log "42")

(* === Auto-DI assertion ===
   A is supposed to be definable without mentioning services.
   Try it. *)

(* This MUST fail to type-check if R-A explicit is honest.
   Uncomment to verify:

let a_no_args id =
  let open Effect in
  let* () = b (Printf.sprintf "fetching %s" id) in
  c id
*)

(* What we get instead: A's signature mentions every service. *)
module type A_SIG = sig
  val a :
    db:Db.t -> log:Log.t -> string -> ([> `Db_err ], string) Effect.t
end

module _ : A_SIG = struct let a = a end
