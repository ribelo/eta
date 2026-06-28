(* F-B: Public Fiber.t handle. Surface: fork, await, interrupt.
   The fork constructor returns a fiber value the user can hold. *)

module Effect = struct
  (* Forward declaration trick: fiber and effect are mutually recursive. *)
  type ('env, 'err, 'a) t =
    | Pure : 'a -> (_, _, 'a) t
    | Sync : ('env -> 'a) -> ('env, _, 'a) t
    | Bind : ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t)
        -> ('env, 'err, 'a) t
    | Fail : 'err -> (_, 'err, _) t
    | Fork : ('env, 'err, 'a) t -> ('env, _, ('err, 'a) fiber) t
    | Await : ('err, 'a) fiber -> (_, 'err, 'a) t
    | Interrupt : (_, 'a) fiber -> (_, _, unit) t

  and ('err, 'a) fiber = {
    promise : ('a, 'err) result Eio.Promise.t;
    cancel  : unit -> unit;
  }

  let pure v = Pure v
  let sync f = Sync f
  let bind k e = Bind (e, k)
  let ( let* ) e k = Bind (e, k)
  let fail e = Fail e
  let fork e = Fork e
  let await f = Await f
  let interrupt f = Interrupt f

  let rec interpret : type env err a.
      env:env -> sw:Eio.Switch.t -> (env, err, a) t -> (a, err) result =
   fun ~env ~sw eff ->
    match eff with
    | Pure v -> Ok v
    | Sync f -> Ok (f env)
    | Fail e -> Error e
    | Bind (e, k) -> (
        match interpret ~env ~sw e with
        | Error e -> Error e
        | Ok v -> interpret ~env ~sw (k v))
    | Fork child ->
        let promise, resolver = Eio.Promise.create () in
        let child_sw = ref None in
        Eio.Fiber.fork ~sw (fun () ->
            try
              Eio.Switch.run @@ fun cs ->
              child_sw := Some cs;
              let r = interpret ~env ~sw:cs child in
              Eio.Promise.resolve resolver r
            with
            | Eio.Cancel.Cancelled _ -> ()
            (* Note: a held fiber outliving its parent scope is a hazard; see neg test. *)
        );
        let cancel () =
          match !child_sw with
          | Some cs -> (try Eio.Switch.fail cs Exit with _ -> ())
          | None -> ()
        in
        Ok { promise; cancel }
    | Await f -> Eio.Promise.await f.promise
    | Interrupt f -> f.cancel (); Ok ()

  let run ~env eff = Eio.Switch.run @@ fun sw -> interpret ~env ~sw eff
end

(* === Surface assertions === *)
module type FIBER_API = sig
  val fork : ('env, 'err, 'a) Effect.t
    -> ('env, _, ('err, 'a) Effect.fiber) Effect.t
  val await : ('err, 'a) Effect.fiber -> (_, 'err, 'a) Effect.t
  val interrupt : (_, 'a) Effect.fiber -> (_, _, unit) Effect.t
end

module _ : FIBER_API = Effect

(* === Typed-error flow through await ===
   If a forked effect can fail with [> `Db_err], does await re-inject
   the typed error into the awaiter's err channel? *)

let check_typed_error_through_await () =
  let open Effect in
  let _ : ('env, [> `Db_err ], int) t =
    let* (f : ([> `Db_err ], int) fiber) = fork (fail `Db_err) in
    await f
  in
  ()

(* === Hazard: fiber outliving its fork scope ===
   With a public Fiber.t, nothing in the type prevents this:

      let escaped =
        let* f = fork big_work in
        pure f             (* return the fiber to outer scope *)

   The fiber's promise becomes dangling: the parent switch may have
   exited, the fiber may be cancelled, await would block forever
   or return error.

   Demonstrate that the type system DOES NOT catch this. *)

let escaped_fiber_compiles () =
  let open Effect in
  let _ : ('env, _, (int, int) fiber) t =
    let* (f : (int, int) fiber) = fork (pure 42) in
    pure f
  in
  ()
