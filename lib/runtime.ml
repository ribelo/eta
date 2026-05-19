module E = Effect
module Sch = Schedule

module Typed_fail : sig
  type key

  val fresh : unit -> key
  val raise_for : key -> 'a -> _

  val with_handler :
    key -> handler:('a -> 'b) -> body:(unit -> 'b) -> 'b
end = struct
  type key = int
  let counter = ref 0
  let fresh () = incr counter; !counter

  exception Typed_failure of int * Obj.t

  let raise_for key value = raise (Typed_failure (key, Obj.repr value))

  let with_handler key ~handler ~body =
    try body () with
    | Typed_failure (k, v) when k = key -> handler (Obj.obj v)
end

type ('env, 'err) t = {
  env : 'env;
  sleep : Duration.t -> unit;
  outer_sw : Eio.Switch.t;
  active : int Atomic.t;
  default_fail_key : Typed_fail.key;
}

let create ~sw ~clock ?sleep ~env () =
  let clock = (clock :> float Eio.Time.clock_ty Eio.Std.r) in
  let sleep =
    match sleep with
    | Some sleep -> sleep
    | None ->
        fun d ->
          let secs = Duration.to_seconds_float d in
          if secs > 0.0 then Eio.Time.sleep clock secs
  in
  {
    env;
    sleep;
    outer_sw = sw;
    active = Atomic.make 0;
    default_fail_key = Typed_fail.fresh ();
  }

let run_finalizers finalizers =
  match !finalizers with
  | [] -> ()
  | fs -> Eio.Fiber.all (List.map (fun f () -> f ()) fs)

let rec interpret :
    type env err a.
    runtime:(env, _) t ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (env, err, a) E.t ->
    env ->
    a =
 fun ~runtime ~fail_key ~sw ~finalizers eff env ->
  match eff with
  | E.Pure v -> v
  | E.Fail e -> Typed_fail.raise_for fail_key e
  | E.Sync (_, f) -> f env
  | E.Async (_, f) -> f env
  | E.Bind (e, k) ->
      let v = interpret ~runtime ~fail_key ~sw ~finalizers e env in
      interpret ~runtime ~fail_key ~sw ~finalizers (k v) env
  | E.Map (e, f) -> f (interpret ~runtime ~fail_key ~sw ~finalizers e env)
  | E.Catch (e, handler) ->
      let inner_key = Typed_fail.fresh () in
      Typed_fail.with_handler inner_key
        ~handler:(fun err ->
          interpret ~runtime ~fail_key ~sw ~finalizers (handler err) env)
        ~body:(fun () ->
          interpret ~runtime ~fail_key:inner_key ~sw ~finalizers e env)
  | E.Tap_error (e, observe) ->
      let inner_key = Typed_fail.fresh () in
      Typed_fail.with_handler inner_key
        ~handler:(fun err ->
          observe err;
          Typed_fail.raise_for fail_key err)
        ~body:(fun () ->
          interpret ~runtime ~fail_key:inner_key ~sw ~finalizers e env)
  | E.Delay (d, e) ->
      runtime.sleep d;
      interpret ~runtime ~fail_key ~sw ~finalizers e env
  | E.Timeout (d, e) ->
      Eio.Fiber.first
        (fun () ->
          runtime.sleep d;
          Typed_fail.raise_for fail_key `Timeout)
        (fun () -> interpret ~runtime ~fail_key ~sw ~finalizers e env)
  | E.Concat children ->
      List.iter
        (fun child ->
          let () = interpret ~runtime ~fail_key ~sw ~finalizers child env in
          ())
        children
  | E.Race children -> race_first ~runtime ~fail_key ~finalizers children env
  | E.Detach e -> detach_effect ~runtime e env
  | E.Repeat (e, schedule) ->
      repeat_eff ~runtime ~fail_key ~sw ~finalizers e schedule env
  | E.Retry (e, schedule, predicate) ->
      retry_eff ~runtime ~fail_key ~sw ~finalizers e schedule predicate env
  | E.Acquire_release (acquire, release) ->
      let v = interpret ~runtime ~fail_key ~sw ~finalizers acquire env in
      finalizers :=
        (fun () ->
          try
            interpret ~runtime ~fail_key:runtime.default_fail_key ~sw
              ~finalizers:(ref []) (release v) env
          with _ -> ())
        :: !finalizers;
      v
  | E.Scoped e ->
      Eio.Switch.run @@ fun sw' ->
      let child_finalizers = ref [] in
      Fun.protect
        ~finally:(fun () -> run_finalizers child_finalizers)
        (fun () ->
          interpret ~runtime ~fail_key ~sw:sw' ~finalizers:child_finalizers e env)
  | E.Named (_, e) -> interpret ~runtime ~fail_key ~sw ~finalizers e env
  | E.Annotate (_, _, e) -> interpret ~runtime ~fail_key ~sw ~finalizers e env

and race_first :
    type env err a.
    runtime:(env, _) t ->
    fail_key:Typed_fail.key ->
    finalizers:(unit -> unit) list ref ->
    (env, err, a) E.t list ->
    env ->
    a =
 fun ~runtime ~fail_key ~finalizers children env ->
  match children with
  | [] -> failwith "Effect.race: empty list"
  | _ ->
      let winner = ref None in
      let n = List.length children in
      let exception Race_won in
      (try
         Eio.Switch.run @@ fun race_sw ->
         let results = Eio.Stream.create n in
         List.iter
           (fun child ->
             Eio.Fiber.fork ~sw:race_sw (fun () ->
                 try
                   let value =
                     interpret ~runtime ~fail_key ~sw:race_sw ~finalizers child
                       env
                   in
                   Eio.Stream.add results (`Ok value)
                 with exn -> Eio.Stream.add results (`Error exn)))
           children;
         let rec await_success first_error remaining =
           if remaining = 0 then
             match first_error with
             | Some exn -> raise exn
             | None -> failwith "Effect.race: no children"
           else
             match Eio.Stream.take results with
             | `Ok value ->
                 winner := Some (Obj.repr value);
                 Eio.Switch.fail race_sw Race_won;
                 Eio.Fiber.await_cancel ()
             | `Error exn ->
                 await_success
                   (match first_error with
                   | Some _ -> first_error
                   | None -> Some exn)
                   (remaining - 1)
         in
         await_success None n
       with Race_won -> Obj.obj (Option.get !winner))

and detach_effect :
    type env err.
    runtime:(env, _) t -> (env, err, unit) E.t -> env -> unit =
 fun ~runtime eff env ->
  Atomic.incr runtime.active;
  Eio.Fiber.fork_daemon ~sw:runtime.outer_sw (fun () ->
      (try
         Eio.Switch.run @@ fun sw' ->
         interpret ~runtime ~fail_key:runtime.default_fail_key ~sw:sw'
           ~finalizers:(ref []) eff env
       with _ -> ());
      Atomic.decr runtime.active;
      `Stop_daemon)

and repeat_eff :
    type env err.
    runtime:(env, _) t ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (env, err, unit) E.t ->
    Sch.t ->
    env ->
    unit =
 fun ~runtime ~fail_key ~sw ~finalizers e schedule env ->
  interpret ~runtime ~fail_key ~sw ~finalizers e env;
  let step = ref 0 in
  let continue = ref true in
  while !continue do
    match Sch.next_delay schedule ~step:!step with
    | None -> continue := false
    | Some d ->
        runtime.sleep d;
        interpret ~runtime ~fail_key ~sw ~finalizers e env;
        incr step
  done

and retry_eff :
    type env err a.
    runtime:(env, _) t ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (env, err, a) E.t ->
    Sch.t ->
    (err -> bool) ->
    env ->
    a =
 fun ~runtime ~fail_key ~sw ~finalizers e schedule predicate env ->
  let attempt_key = Typed_fail.fresh () in
  let step = ref 0 in
  let result : a option ref = ref None in
  while Option.is_none !result do
    Typed_fail.with_handler attempt_key
      ~handler:(fun err ->
        if predicate err then
          match Sch.next_delay schedule ~step:!step with
          | Some d ->
              runtime.sleep d;
              incr step
          | None -> Typed_fail.raise_for fail_key err
        else Typed_fail.raise_for fail_key err)
      ~body:(fun () ->
        let v =
          interpret ~runtime ~fail_key:attempt_key ~sw ~finalizers e env
        in
        result := Some v)
  done;
  Option.get !result

let run t eff =
  Eio.Switch.run @@ fun sw ->
  let finalizers = ref [] in
  Typed_fail.with_handler t.default_fail_key
    ~handler:(fun err -> Error err)
    ~body:(fun () ->
      Ok (interpret ~runtime:t ~fail_key:t.default_fail_key ~sw ~finalizers eff
            t.env))

let run_exn t eff =
  match run t eff with
  | Ok value -> value
  | Error _ -> failwith "Effet.Runtime.run_exn"

let drain t =
  while Atomic.get t.active > 0 do
    Eio.Fiber.yield ()
  done
