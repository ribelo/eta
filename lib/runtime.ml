module E = Effect
module Sch = Schedule

exception Raised_cause of int * Obj.t

module Typed_fail : sig
  type key

  val fresh : unit -> key
  val int : key -> int
end = struct
  type key = int
  let counter = ref 0
  let fresh () = incr counter; !counter
  let int key = key
end

let raise_cause key cause =
  raise (Raised_cause (Typed_fail.int key, Obj.repr cause))

let raise_fail key err = raise_cause key (Cause.Fail err)

let cause_of_exn key exn =
  match exn with
  | Raised_cause (k, cause) when k = Typed_fail.int key -> Obj.obj cause
  | Eio.Cancel.Cancelled _ -> Cause.Interrupt
  | exn -> Cause.Die exn

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
    type re env err a.
    runtime:(re, _) t ->
    fail_key:Typed_fail.key ->
    sw:Eio.Switch.t ->
    finalizers:(unit -> unit) list ref ->
    (env, err, a) E.t ->
    env ->
    a =
 fun ~runtime ~fail_key ~sw ~finalizers eff env ->
  match eff with
  | E.Pure v -> v
  | E.Fail e -> raise_fail fail_key e
  | E.Sync (_, f) -> f env
  | E.Async (_, f) -> f env
  | E.Bind (e, k) ->
      let v = interpret ~runtime ~fail_key ~sw ~finalizers e env in
      interpret ~runtime ~fail_key ~sw ~finalizers (k v) env
  | E.Map (e, f) -> f (interpret ~runtime ~fail_key ~sw ~finalizers e env)
  | E.Catch (e, handler) ->
      let inner_key = Typed_fail.fresh () in
      (try interpret ~runtime ~fail_key:inner_key ~sw ~finalizers e env with
      | Raised_cause (k, cause) when k = Typed_fail.int inner_key -> (
          match Obj.obj cause with
          | Cause.Fail err ->
              interpret ~runtime ~fail_key ~sw ~finalizers (handler err) env
          | cause -> raise_cause fail_key cause)
      | Eio.Cancel.Cancelled _ -> raise_cause fail_key Cause.Interrupt
      | exn -> raise_cause fail_key (Cause.Die exn))
  | E.Tap_error (e, observe) ->
      let inner_key = Typed_fail.fresh () in
      (try interpret ~runtime ~fail_key:inner_key ~sw ~finalizers e env with
      | Raised_cause (k, cause) when k = Typed_fail.int inner_key -> (
          match Obj.obj cause with
          | Cause.Fail err ->
              observe err;
              raise_fail fail_key err
          | cause -> raise_cause fail_key cause)
      | Eio.Cancel.Cancelled _ -> raise_cause fail_key Cause.Interrupt
      | exn -> raise_cause fail_key (Cause.Die exn))
  | E.Delay (d, e) ->
      runtime.sleep d;
      interpret ~runtime ~fail_key ~sw ~finalizers e env
  | E.Timeout (d, e) ->
      Eio.Fiber.first
        (fun () ->
          runtime.sleep d;
          raise_fail fail_key `Timeout)
        (fun () -> interpret ~runtime ~fail_key ~sw ~finalizers e env)
  | E.Concat children ->
      List.iter
        (fun child ->
          let () = interpret ~runtime ~fail_key ~sw ~finalizers child env in
          ())
        children
  | E.Race children -> race_first ~runtime ~fail_key ~finalizers children env
  | E.Par (a, b) ->
      let tasks : (env -> Obj.t) list =
        [
          (fun env ->
            Obj.repr
              (interpret ~runtime ~fail_key ~sw ~finalizers a env));
          (fun env ->
            Obj.repr
              (interpret ~runtime ~fail_key ~sw ~finalizers b env));
        ]
      in
      (match
         par_collect ~runtime ~fail_key ~finalizers tasks env
       with
       | [ va; vb ] -> (Obj.obj va, Obj.obj vb)
       | _ -> assert false)
  | E.All children ->
      par_collect ~runtime ~fail_key ~finalizers
        (List.map
           (fun child env ->
             interpret ~runtime ~fail_key ~sw ~finalizers child env)
           children)
        env
  | E.For_each_par (xs, f) ->
      par_collect ~runtime ~fail_key ~finalizers
        (List.map
           (fun x env ->
             interpret ~runtime ~fail_key ~sw ~finalizers (f x) env)
           xs)
        env
  | E.Detach e -> detach_effect ~runtime e env
  | E.Uninterruptible e ->
      Eio.Cancel.protect (fun () ->
          interpret ~runtime ~fail_key ~sw ~finalizers e env)
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
  | E.Provide (env_in, e) ->
      interpret ~runtime ~fail_key ~sw ~finalizers e env_in

and par_collect :
    type re env err a.
    runtime:(re, _) t ->
    fail_key:Typed_fail.key ->
    finalizers:(unit -> unit) list ref ->
    (env -> a) list ->
    env ->
    a list =
 fun ~runtime:_ ~fail_key ~finalizers:_ tasks env ->
  let n = List.length tasks in
  let results : a option array = Array.make n None in
  let first_cause : err Cause.t option ref = ref None in
  let exception Stop in
  (try
     Eio.Switch.run @@ fun par_sw ->
     List.iteri
       (fun i task ->
         Eio.Fiber.fork ~sw:par_sw (fun () ->
             try results.(i) <- Some (task env)
             with exn ->
               let cause = cause_of_exn fail_key exn in
               (match !first_cause with
                | Some _ -> ()
                | None -> first_cause := Some cause);
               (try Eio.Switch.fail par_sw Stop with _ -> ())))
       tasks
   with Stop -> ());
  match !first_cause with
  | Some c -> raise_cause fail_key c
  | None -> Array.to_list results |> List.map Option.get

and race_first :
    type re env err a.
    runtime:(re, _) t ->
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
                 with exn ->
                   Eio.Stream.add results (`Error (cause_of_exn fail_key exn))))
           children;
         let rec await_success cause remaining =
           if remaining = 0 then
             match cause with
             | Some cause -> raise_cause fail_key cause
             | None -> failwith "Effect.race: no children"
           else
             match Eio.Stream.take results with
             | `Ok value ->
                 winner := Some (Obj.repr value);
                 Eio.Switch.fail race_sw Race_won;
                 Eio.Fiber.await_cancel ()
             | `Error child_cause ->
                 await_success
                   (match cause with
                   | Some cause -> Some (Cause.Both (cause, child_cause))
                   | None -> Some child_cause)
                   (remaining - 1)
         in
         await_success None n
       with Race_won -> Obj.obj (Option.get !winner))

and detach_effect :
    type re env err.
    runtime:(re, _) t -> (env, err, unit) E.t -> env -> unit =
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
    type re env err.
    runtime:(re, _) t ->
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
    type re env err a.
    runtime:(re, _) t ->
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
    (try
       let v =
         interpret ~runtime ~fail_key:attempt_key ~sw ~finalizers e env
       in
       result := Some v
     with
     | Raised_cause (k, cause) when k = Typed_fail.int attempt_key -> (
         match Obj.obj cause with
         | Cause.Fail err ->
             if predicate err then
               match Sch.next_delay schedule ~step:!step with
               | Some d ->
                   runtime.sleep d;
                   incr step
               | None -> raise_fail fail_key err
             else raise_fail fail_key err
         | cause -> raise_cause fail_key cause)
     | Eio.Cancel.Cancelled _ -> raise_cause fail_key Cause.Interrupt
     | exn -> raise_cause fail_key (Cause.Die exn))
  done;
  Option.get !result

let run t eff =
  Eio.Switch.run @@ fun sw ->
  let finalizers = ref [] in
  try
    Exit.Ok
      (interpret ~runtime:t ~fail_key:t.default_fail_key ~sw ~finalizers eff
         t.env)
  with exn -> Exit.Error (cause_of_exn t.default_fail_key exn)

let run_exn t eff =
  match run t eff with
  | Exit.Ok value -> value
  | Exit.Error (Cause.Die exn) -> raise exn
  | Exit.Error _ -> failwith "Effet.Runtime.run_exn"

let drain t =
  while Atomic.get t.active > 0 do
    Eio.Fiber.yield ()
  done
