[@@@warning "-21"]

(* F-D: scoped supervisor.

   A supervisor value and every child handle carry a phantom scope tag ['s].
   The only way to obtain the tag is through [supervise { run = ... }], whose
   body is rank-2-polymorphic. Returning a child handle from the body would leak
   ['s], so the compiler rejects it. *)

module Effect = struct
  type 'err cause =
    | Fail of 'err
    | Die of string
    | Interrupt
    | Both of 'err cause * 'err cause

  type ('env, 'err, 'a) t =
    | Pure : 'a -> (_, _, 'a) t
    | Fail : 'err -> (_, 'err, _) t
    | Sync : ('env -> 'a) -> ('env, _, 'a) t
    | Bind :
        ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t)
        -> ('env, 'err, 'a) t
    | Supervise :
        int option * ('env, 'err, 'a) supervisor_body -> ('env, 'err, 'a) t

  and ('s, 'env, 'err, 'a) scoped_t =
    | S_pure : 'a -> (_, _, _, 'a) scoped_t
    | S_lift : ('env, 'err, 'a) t -> (_, 'env, 'err, 'a) scoped_t
    | S_fail : 'err -> (_, _, 'err, _) scoped_t
    | S_bind :
        ('s, 'env, 'err, 'b) scoped_t *
        ('b -> ('s, 'env, 'err, 'a) scoped_t)
        -> ('s, 'env, 'err, 'a) scoped_t
    | S_start :
        ('s, 'err) supervisor * ('s, 'env, 'err, 'a) scoped_t
        -> ('s, 'env, _, ('s, 'err, 'a) child) scoped_t
    | S_await : ('s, 'err, 'a) child -> ('s, _, 'err, 'a) scoped_t
    | S_cancel : ('s, _, _) child -> ('s, _, _, unit) scoped_t
    | S_observe :
        ('s, 'err) supervisor -> ('s, _, _, 'err cause list) scoped_t
    | S_check_threshold :
        ('s, [> `Supervisor_failed of int ] as 'err) supervisor
        -> ('s, _, 'err, unit) scoped_t
    | S_yield : ('s, _, _, unit) scoped_t
    | S_never : ('s, _, _, unit) scoped_t
    | S_ensure :
        ('s, 'env, 'err, 'a) scoped_t * (unit -> unit)
        -> ('s, 'env, 'err, 'a) scoped_t

  and ('env, 'err, 'a) supervisor_body = {
    run : 's. ('s, 'err) supervisor -> ('s, 'env, 'err, 'a) scoped_t;
  }

  and ('s, 'err) supervisor = {
    sw : Eio.Switch.t;
    max_failures : int option;
    failures : 'err cause list ref;
  }

  and ('s, 'err, 'a) child = {
    promise : ('a, 'err cause) result Eio.Promise.t;
    cancel : unit -> unit;
  }

  let pure v = Pure v
  let fail err = Fail err
  let sync f = Sync f
  let bind k e = Bind (e, k)
  let ( let* ) e k = Bind (e, k)
  let supervise ?max_failures body = Supervise (max_failures, body)

  let s_pure v = S_pure v
  let s_lift e = S_lift e
  let s_fail err = S_fail err
  let s_bind k e = S_bind (e, k)
  let ( let** ) e k = S_bind (e, k)
  let start sup e = S_start (sup, e)
  let await child = S_await child
  let cancel child = S_cancel child
  let observe sup = S_observe sup
  let check_threshold sup = S_check_threshold sup
  let yield = S_yield
  let never = S_never
  let ensure ~finally e = S_ensure (e, finally)

  let add_failure sup cause =
    sup.failures := cause :: !(sup.failures)

  let threshold_reached sup =
    match sup.max_failures with
    | None -> false
    | Some max -> List.length !(sup.failures) >= max

  let resolve_once resolver =
    let resolved = ref false in
    fun value ->
      if not !resolved then (
        resolved := true;
        Eio.Promise.resolve resolver value)

  let cause_of_exn = function
    | Eio.Cancel.Cancelled _ -> Interrupt
    | Exit -> Interrupt
    | exn -> Die (Printexc.to_string exn)

  let rec interpret : type env err a.
      env:env -> sw:Eio.Switch.t -> (env, err, a) t -> (a, err cause) result =
   fun ~env ~sw eff ->
    match eff with
    | Pure value -> Ok value
    | Fail err -> Error (Fail err)
    | Sync f -> Ok (f env)
    | Bind (e, k) -> (
        match interpret ~env ~sw e with
        | Error cause -> Error cause
        | Ok value -> interpret ~env ~sw (k value))
    | Supervise (max_failures, body) ->
        Eio.Switch.run @@ fun child_sw ->
        let sup = { sw = child_sw; max_failures; failures = ref [] } in
        interpret_scoped ~env ~sw:child_sw (body.run sup)

  and interpret_scoped : type s env err a.
      env:env ->
      sw:Eio.Switch.t ->
      (s, env, err, a) scoped_t ->
      (a, err cause) result =
   fun ~env ~sw eff ->
    match eff with
    | S_pure value -> Ok value
    | S_lift e -> interpret ~env ~sw e
    | S_fail err -> Error (Fail err)
    | S_bind (e, k) -> (
        match interpret_scoped ~env ~sw e with
        | Error cause -> Error cause
        | Ok value -> interpret_scoped ~env ~sw (k value))
    | S_start (sup, child_eff) ->
        let promise, resolver = Eio.Promise.create () in
        let resolve = resolve_once resolver in
        let child_sw = ref None in
        Eio.Fiber.fork ~sw:sup.sw (fun () ->
            let result =
              try
                Eio.Switch.run @@ fun sw' ->
                child_sw := Some sw';
                interpret_scoped ~env ~sw:sw' child_eff
              with exn -> Error (cause_of_exn exn)
            in
            (match result with
             | Ok _ -> ()
             | Error cause -> add_failure sup cause);
            resolve result);
        let cancel () =
          match !child_sw with
          | None -> resolve (Error Interrupt)
          | Some sw' ->
              (try Eio.Switch.fail sw' Exit with _ -> ())
        in
        Ok { promise; cancel }
    | S_await child -> Eio.Promise.await child.promise
    | S_cancel child ->
        child.cancel ();
        Ok ()
    | S_observe sup -> Ok (List.rev !(sup.failures))
    | S_check_threshold sup ->
        if threshold_reached sup then
          Error (Fail (`Supervisor_failed (List.length !(sup.failures))))
        else Ok ()
    | S_yield ->
        Eio.Fiber.yield ();
        Ok ()
    | S_never ->
        Eio.Fiber.await_cancel ();
        Error Interrupt
    | S_ensure (e, finally) ->
        Fun.protect ~finally (fun () -> interpret_scoped ~env ~sw e)

  let run ~env eff =
    Eio_main.run @@ fun _ ->
    Eio.Switch.run @@ fun sw -> interpret ~env ~sw eff
end

module type SUPERVISOR_SCOPE_SIG = sig
  val observe_child_failure :
    unit ->
    (unit, ([> `Boom | `Supervisor_failed of int ] as 'err), 'err Effect.cause list) Effect.t

  val await_child_result : unit -> (unit, ([> `Boom ] as 'err), int) Effect.t
  val threshold_failure :
    unit ->
    (unit, ([> `Boom | `Supervisor_failed of int ] as 'err), unit) Effect.t
  val resource_auto_refresh_observable :
    unit ->
    (unit, ([> `Refresh | `Supervisor_failed of int ] as 'err),
     int * 'err Effect.cause list)
    Effect.t
end

let observe_child_failure :
    unit ->
    (unit, [> `Boom | `Supervisor_failed of int ],
     [> `Boom | `Supervisor_failed of int ] Effect.cause list)
    Effect.t =
 fun () ->
  let open Effect in
  supervise {
    run = fun (type s) sup ->
      let** (_child : (s, [> `Boom | `Supervisor_failed of int ], int) child) =
        start sup (s_fail `Boom)
      in
      let** () = yield in
      observe sup
  }

let await_child_result : unit -> (unit, [> `Boom ], int) Effect.t =
 fun () ->
  let open Effect in
  supervise {
    run = fun (type s) sup ->
      let** (child : (s, [> `Boom ], int) child) = start sup (s_pure 42) in
      await child
  }

let threshold_failure :
    unit ->
    (unit, [> `Boom | `Supervisor_failed of int ], unit) Effect.t =
 fun () ->
  let open Effect in
  supervise ~max_failures:1 {
    run = fun (type s) sup ->
      let** (_child : (s, [> `Boom | `Supervisor_failed of int ], int) child) =
        start sup (s_fail `Boom)
      in
      let** () = yield in
      check_threshold sup
  }

let resource_auto_refresh_observable :
    unit ->
    (unit, [> `Refresh | `Supervisor_failed of int ],
     int * [> `Refresh | `Supervisor_failed of int ] Effect.cause list)
    Effect.t =
 fun () ->
  let open Effect in
  supervise {
    run =
      fun (type s) sup ->
        let cache = ref 1 in
        let refresh = s_fail `Refresh in
        let** (_child :
                (s, [> `Refresh | `Supervisor_failed of int ], unit) child) =
          start sup refresh
        in
        let** () = yield in
        let** failures = observe sup in
        s_pure (!cache, failures)
  }

module _ : SUPERVISOR_SCOPE_SIG = struct
  let observe_child_failure = observe_child_failure
  let await_child_result = await_child_result
  let threshold_failure = threshold_failure
  let resource_auto_refresh_observable = resource_auto_refresh_observable
end
