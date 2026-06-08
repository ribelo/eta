(* R-C: services via functor. No 'env, no threading inside the
   functor body, but the application must instantiate the functor. *)

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

(* Service module types. *)
module type DB  = sig val query : string -> string end
module type LOG = sig val info  : string -> unit  end

(* Each "feature module" is a functor. *)
module Make_C (D : DB) = struct
  let c id : ([> `Db_err ], string) Effect.t =
    Effect.sync (fun () -> D.query id)
end

module Make_B (L : LOG) = struct
  let b msg : (_, unit) Effect.t =
    Effect.sync (fun () -> L.info msg)
end

(* A is also a functor; it must compose B and C. *)
module Make_A (D : DB) (L : LOG) = struct
  module B = Make_B (L)
  module C = Make_C (D)

  (* INSIDE the functor body A looks DI-clean. *)
  let a id =
    let open Effect in
    let* () = B.b (Printf.sprintf "fetching %s" id) in
    C.c id
end

(* Boot: instantiate functors with concrete impls. *)
let boot () =
  let module D : DB = struct
    let db = Services.Db.make "main"
    let query sql = Services.Db.query db sql
  end in
  let module L : LOG = struct
    let log = Services.Log.make "[info] "
    let info msg = Services.Log.info log msg
  end in
  let module App = Make_A (D) (L) in
  Effect.run (App.a "42")

(* === Observations ===
   - Auto-DI within a functor body: yes (A doesn't mention services).
   - But every consuming module must be a functor too, and A must
     reapply Make_B and Make_C.
   - If a NEW dependency is added to a leaf, every functor up the
     chain gains a new parameter. Editing A means editing every
     intermediate functor signature.
   - You cannot define `a` at top level without `Make_A` wrapping it.
*)
