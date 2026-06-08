(* R-A composite: one services-bag argument, threaded as a value.
   No 'env on the effect type. *)

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

(* Helpers demand a bag containing what they need. *)
let c (s : < db : db; .. >) id : ([> `Db_err ], string) Effect.t =
  Effect.sync (fun () -> s#db#query id)

let b (s : < log : log; .. >) msg : (_, unit) Effect.t =
  Effect.sync (fun () -> s#log#info msg)

(* A threads s but does NOT name db or log. *)
let a s id =
  let open Effect in
  let* () = b s (Printf.sprintf "fetching %s" id) in
  c s id

(* Boot. *)
let boot () =
  let services =
    object
      method db = db_of (Db.make "main")
      method log = log_of (Log.make "[info] ")
    end
  in
  Effect.run (a services "42")

(* === Auto-DI assertion ===
   A still needs to thread `s`. But A's signature has the row UNION
   of B's and C's requirements, inferred automatically. *)

module type A_SIG = sig
  val a :
    < db : db; log : log; .. > ->
    string ->
    ([> `Db_err ], string) Effect.t
end

module _ : A_SIG = struct let a = a end

(* What you can NOT do: define A without taking `s` as an argument. *)
(* Uncomment to verify it fails:

let a_no_arg id =
  let open Effect in
  let* () = b (Printf.sprintf "fetching %s" id) in
  c id
*)
