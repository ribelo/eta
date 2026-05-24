open Runtime_core
module E = Effect
module EV = Effect_ast
module RObs = Runtime_observability
module P_atomic = Portable.Atomic

let par_collect :
    type err a.
    runtime:_ t ->
    fail_key:Typed_fail.key ->
    finalizers:(unit -> unit) list ref ->
    (unit -> a) list ->
    a list =
 fun ~runtime ~fail_key ~finalizers:_ tasks ->
  let n = List.length tasks in
  let results : a option array = Array.make n None in
  let causes : err Cause.t list ref = ref [] in
  let exception Stop in
  (try
     Eio.Switch.run @@ fun par_sw ->
     List.iteri
       (fun i task ->
         Eio.Fiber.fork ~sw:par_sw (fun () ->
           runtime.tracer#with_fiber_context @@ fun () ->
             try results.(i) <- Some (task ())
             with exn ->
               let cause = cause_of_exn_runtime runtime fail_key exn in
               causes := cause :: !causes;
               (try Eio.Switch.fail par_sw Stop with _ -> ())))
       tasks
   with Stop -> ());
  match List.rev !causes with
  | [] -> Array.to_list results |> List.map Option.get
  | causes -> raise_cause fail_key (Cause.concurrent causes)

let race_first :
    type err a.
    runtime:_ t ->
    interpret_ast:(runtime:_ t -> error_renderer:(err -> string) -> fail_key:Typed_fail.key -> sw:Eio.Switch.t -> finalizers:(unit -> unit) list ref -> (a, err) EV.t -> a) ->
    error_renderer:(err -> string) ->
    fail_key:Typed_fail.key ->
    finalizers:(unit -> unit) list ref ->
    (a, err) EV.t list ->
    a =
 fun ~runtime ~interpret_ast ~error_renderer ~fail_key ~finalizers children ->
  match children with
  | [] -> failwith "Effect.race: empty list"
  | _ ->
      (* The local [Race_won] exception cannot carry the existential success
         type [a]. [winner] never leaves this frame and is unpacked only after
         the winning child stores a value of that same [a]. *)
      let winner = ref None in
      let n = List.length children in
      let exception Race_won in
      (try
         Eio.Switch.run @@ fun race_sw ->
         let results = Eio.Stream.create n in
         List.iter
           (fun child ->
             Eio.Fiber.fork ~sw:race_sw (fun () ->
                runtime.tracer#with_fiber_context @@ fun () ->
                try
                  let value =
                    interpret_ast ~runtime ~error_renderer ~fail_key
                      ~sw:race_sw
                      ~finalizers child
                  in
                  Eio.Stream.add results (`Ok value)
                with exn ->
                  Eio.Stream.add results
                    (`Error (cause_of_exn_runtime runtime fail_key exn))))
           children;
         let rec await_success causes remaining =
           if remaining = 0 then
             match List.rev causes with
             | [] -> failwith "Effect.race: no children"
             | causes -> raise_cause fail_key (Cause.concurrent causes)
           else
             match Eio.Stream.take results with
             | `Ok value ->
                 winner := Some (Obj.repr value);
                 Eio.Switch.fail race_sw Race_won;
                 Eio.Fiber.await_cancel ()
             | `Error child_cause ->
                 await_success (child_cause :: causes) (remaining - 1)
         in
         await_success [] n
       with Race_won -> Obj.obj (Option.get !winner))

let par_collect_settled :
    type err a.
    runtime:_ t ->
    interpret_ast:(runtime:_ t -> error_renderer:(err -> string) -> fail_key:Typed_fail.key -> sw:Eio.Switch.t -> finalizers:(unit -> unit) list ref -> (a, err) EV.t -> a) ->
    error_renderer:(err -> string) ->
    fail_key:Typed_fail.key ->
    finalizers:(unit -> unit) list ref ->
    (a, err) EV.t list ->
    (a, err Cause.t) result list =
 fun ~runtime ~interpret_ast ~error_renderer ~fail_key ~finalizers children ->
  let n = List.length children in
  let results : (a, err Cause.t) result option array = Array.make n None in
  (Eio.Switch.run @@ fun par_sw ->
   List.iteri
     (fun i child ->
       Eio.Fiber.fork ~sw:par_sw (fun () ->
           runtime.tracer#with_fiber_context @@ fun () ->
           results.(i) <-
             Some
               (try
                  Ok
                    (interpret_ast ~runtime ~error_renderer ~fail_key
                       ~sw:par_sw
                       ~finalizers child)
                with exn ->
                  Error (cause_of_exn_runtime runtime fail_key exn))))
     children);
  Array.to_list results |> List.map Option.get


let fork_internal :
    type err.
    runtime:_ t ->
    interpret_ast:
      (runtime:_ t ->
      error_renderer:(err -> string) ->
      fail_key:Typed_fail.key ->
      sw:Eio.Switch.t ->
      finalizers:(unit -> unit) list ref ->
      (unit, err) EV.t ->
      unit) ->
    (unit, err) EV.t ->
    unit =
 fun ~runtime ~interpret_ast eff ->
  P_atomic.incr runtime.active;
  Eio.Fiber.fork_daemon ~sw:runtime.outer_sw (fun () ->
      runtime.tracer#with_fiber_context @@ fun () ->
      Fun.protect
        ~finally:(fun () -> P_atomic.decr runtime.active)
        (fun () ->
          (try
             Eio.Switch.run @@ fun sw' ->
             let finalizers = ref [] in
             with_finalizers ~runtime ~fail_key:runtime.default_fail_key
               finalizers (fun () ->
                 interpret_ast ~runtime ~error_renderer:RObs.default_error_renderer
                   ~fail_key:runtime.default_fail_key ~sw:sw' ~finalizers eff)
           with exn ->
             cause_of_exn_runtime runtime runtime.default_fail_key exn
             |> emit_daemon_failure runtime);
          `Stop_daemon))
