(* R-E: First-class modules threaded as a single value.
   Like R-A composite but using FCM instead of objects. *)

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

module type DB  = sig val query : string -> string end
module type LOG = sig val info  : string -> unit  end

(* Helpers take FCM values. *)
let c (module D : DB) id : ([> `Db_err ], string) Effect.t =
  Effect.sync (fun () -> D.query id)

let b (module L : LOG) msg : (_, unit) Effect.t =
  Effect.sync (fun () -> L.info msg)

(* A must thread BOTH FCM values explicitly. There is no row union
   on first-class modules. *)
let a (module D : DB) (module L : LOG) id =
  let open Effect in
  let* () = b (module L : LOG) (Printf.sprintf "fetching %s" id) in
  c (module D : DB) id

(* === Observations ===
   - No row polymorphism on FCM; you cannot pass a single bag.
   - A must accept and forward each module separately.
   - This is strictly worse than R-A explicit (more verbose) and
     worse than R-A composite (no row union). *)
