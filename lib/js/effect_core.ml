type context = {
  scheduler : Scheduler.t;
  fiber : Runtime_fiber.t;
  clock : Runtime_core.clock;
  daemon_started : unit -> unit;
  daemon_finished : unit -> unit;
  daemon_failed : Obj.t Cause.t -> unit;
}

type ('a, +'err) t =
  | Pure : 'a -> ('a, 'err) t
  | Fail : 'err -> ('a, 'err) t
  | Sync : (unit -> 'a) -> ('a, 'err) t
  | Yield : (unit, 'err) t
  | Check : (unit, 'err) t
  | Async :
      {
        name : string option;
        register :
          context ->
          resume:(('a, 'err) Exit.t -> unit) ->
          on_cancel:((unit -> unit) -> unit) ->
          unit;
      }
      -> ('a, 'err) t
  | Map :
      {
        inner : ('a, 'err) t;
        f : 'a -> 'b;
      }
      -> ('b, 'err) t
  | Bind :
      {
        inner : ('a, 'err) t;
        k : 'a -> ('b, 'err) t;
      }
      -> ('b, 'err) t
  | Catch :
      {
        inner : ('a, 'err) t;
        handler : 'err -> ('a, 'err2) t;
      }
      -> ('a, 'err2) t
  | Map_error :
      {
        inner : ('a, 'err) t;
        f : 'err -> 'err2;
      }
      -> ('a, 'err2) t
  | Finally :
      {
        inner : ('a, 'err) t;
        cleanup : (unit, 'cleanup_err) t;
      }
      -> ('a, 'err) t
  | Uninterruptible :
      {
        inner : ('a, 'err) t;
      }
      -> ('a, 'err) t

let pure value = Pure value
let fail err = Fail err
let sync f = Sync f
let yield_now = Yield
let check = Check
let map f inner = Map { inner; f }
let bind k inner = Bind { inner; k }
let catch handler inner = Catch { inner; handler }
let map_error f inner = Map_error { inner; f }
let finally cleanup inner = Finally { inner; cleanup }
let uninterruptible inner = Uninterruptible { inner }
let async_leaf ?name register = Async { name; register }

let exit_die exn = Exit.error (Cause.die exn)

type packed = Eff : ('a, 'err) t -> packed

type frame =
  | Map_frame of (Obj.t -> Obj.t)
  | Bind_frame of (Obj.t -> packed)
  | Catch_frame of (Obj.t -> packed)
  | Map_error_frame of (Obj.t -> Obj.t)
  | Finally_frame of packed
  | Uninterruptible_frame of bool
  | Finalizer_success_frame of Obj.t
  | Finalizer_error_frame of Obj.t Cause.t

let erased_die exn : Obj.t Cause.t = Cause.die exn
let render_finalizer_failure _ = "<typed finalizer failure>"
let finalizer_cause cause = Cause.finalizer_of_cause render_finalizer_failure cause

let cancel_hook_cause hooks =
  let causes =
    List.filter_map
      (fun hook ->
        try
          hook ();
          None
        with exn -> Some (erased_die exn))
      hooks
  in
  match causes with
  | [] -> None
  | [ cause ] -> Some cause
  | causes -> Some (Cause.sequential causes)

type state =
  | Eval of packed
  | Success of Obj.t
  | Error of Obj.t Cause.t

let run_promise : type a err. context -> (a, err) t -> (a, err) Exit.t Js.Promise.t =
 fun context eff ->
  Js.Promise.make (fun ~resolve ~reject:_ ->
      let finished = ref false in
      let finish (exit : (Obj.t, Obj.t) Exit.t) =
        if not !finished then begin
          finished := true;
          resolve (Obj.magic exit) [@u]
        end
      in
      let rec drive initial_state initial_stack =
        let state = ref initial_state in
        let stack = ref initial_stack in
        let stopped = ref false in
        while (not !stopped) && not !finished do
          match !state with
          | Eval (Eff eff) -> (
              match eff with
              | Pure value -> state := Success (Obj.repr value)
              | Fail err -> state := Error (Cause.fail (Obj.repr err))
              | Sync f -> (
                  try state := Success (Obj.repr (f ()))
                  with exn -> state := Error (erased_die exn))
              | Yield ->
                  stopped := true;
                  Scheduler.enqueue context.scheduler (fun () ->
                      drive (Success (Obj.repr ())) !stack)
              | Check -> (
                  match Runtime_fiber.cancel_cause context.fiber with
                  | Some cause when Runtime_fiber.interruptible context.fiber ->
                      state := Error cause
                  | _ -> state := Success (Obj.repr ()))
              | Uninterruptible { inner } ->
                  let was_interruptible =
                    Runtime_fiber.interruptible context.fiber
                  in
                  Runtime_fiber.set_interruptible context.fiber false;
                  stack :=
                    Uninterruptible_frame was_interruptible :: !stack;
                  state := Eval (Eff inner)
              | Async { register; _ } ->
                  stopped := true;
                  suspend register !stack
              | Map { inner; f } ->
                  stack :=
                    Map_frame (fun value -> Obj.repr (f (Obj.obj value)))
                    :: !stack;
                  state := Eval (Eff inner)
              | Bind { inner; k } ->
                  stack :=
                    Bind_frame (fun value -> Eff (k (Obj.obj value))) :: !stack;
                  state := Eval (Eff inner)
              | Catch { inner; handler } ->
                  stack :=
                    Catch_frame (fun err -> Eff (handler (Obj.obj err))) :: !stack;
                  state := Eval (Eff inner)
              | Map_error { inner; f } ->
                  stack :=
                    Map_error_frame
                      (fun err -> Obj.repr (f (Obj.obj err)))
                    :: !stack;
                  state := Eval (Eff inner)
              | Finally { inner; cleanup } ->
                  stack := Finally_frame (Eff cleanup) :: !stack;
                  state := Eval (Eff inner))
          | Success value -> (
              match !stack with
              | [] ->
                  stopped := true;
                  finish (Exit.Ok value)
              | frame :: rest -> (
                  stack := rest;
                  match frame with
                  | Map_frame f -> (
                      try state := Success (f value)
                      with exn -> state := Error (erased_die exn))
                  | Bind_frame k -> (
                      try state := Eval (k value)
                      with exn -> state := Error (erased_die exn))
                  | Catch_frame _ | Map_error_frame _ -> state := Success value
                  | Uninterruptible_frame was_interruptible ->
                      Runtime_fiber.set_interruptible context.fiber
                        was_interruptible
                  | Finally_frame cleanup ->
                      stack := Finalizer_success_frame value :: !stack;
                      state := Eval cleanup
                  | Finalizer_success_frame original ->
                      state := Success original
                  | Finalizer_error_frame primary -> state := Error primary))
          | Error cause -> (
              match !stack with
              | [] ->
                  stopped := true;
                  finish (Exit.Error cause)
              | frame :: rest -> (
                  stack := rest;
                  match frame with
                  | Map_frame _ | Bind_frame _ -> state := Error cause
                  | Catch_frame handler -> (
                      match cause with
                      | Cause.Fail err -> (
                          try state := Eval (handler err)
                          with exn -> state := Error (erased_die exn))
                      | Cause.Die _ | Interrupt _ | Sequential _ | Concurrent _
                      | Finalizer _ | Suppressed _ ->
                          state := Error cause)
                  | Map_error_frame f -> (
                      try state := Error (Cause.map f cause)
                      with exn -> state := Error (erased_die exn))
                  | Uninterruptible_frame was_interruptible ->
                      Runtime_fiber.set_interruptible context.fiber
                        was_interruptible
                  | Finally_frame cleanup ->
                      stack := Finalizer_error_frame cause :: !stack;
                      state := Eval cleanup
                  | Finalizer_success_frame _ ->
                      state := Error (Cause.finalizer (finalizer_cause cause))
                  | Finalizer_error_frame primary ->
                      state :=
                        Error
                          (Cause.suppressed ~primary
                             ~finalizer:(finalizer_cause cause))))
        done
      and suspend :
          type a err.
          (context ->
          resume:((a, err) Exit.t -> unit) ->
          on_cancel:((unit -> unit) -> unit) ->
          unit) ->
          frame list ->
          unit =
       fun register stack ->
        let resumed = ref false in
        let cancelling = ref false in
        let cancel_hooks = ref [] in
        let resume exit =
          if !resumed then
            invalid_arg "Eta_js.Effect.Expert.async_leaf: resume called twice";
          resumed := true;
          Scheduler.enqueue context.scheduler (fun () ->
              Runtime_fiber.set_cancel_waiter context.fiber None;
              match exit with
              | Exit.Ok value -> drive (Success (Obj.repr value)) stack
              | Exit.Error cause -> drive (Error (Obj.magic cause)) stack)
        in
        let on_cancel hook = cancel_hooks := hook :: !cancel_hooks in
        let cancel cause =
          if (not !resumed) && not !cancelling
             && Runtime_fiber.interruptible context.fiber
          then begin
            cancelling := true;
            let cause =
              match cancel_hook_cause !cancel_hooks with
              | None -> cause
              | Some finalizer ->
                  Cause.suppressed ~primary:cause
                    ~finalizer:(finalizer_cause finalizer)
            in
            resume (Exit.error cause)
          end
        in
        Runtime_fiber.set_cancel_waiter context.fiber
          (Some
             (fun () ->
               match Runtime_fiber.cancel_cause context.fiber with
               | None -> ()
               | Some cause -> cancel cause));
        (try register context ~resume ~on_cancel
         with exn ->
           Runtime_fiber.set_cancel_waiter context.fiber None;
           if not !resumed then resume (exit_die exn));
        (match Runtime_fiber.cancel_cause context.fiber with
        | None -> ()
        | Some cause -> cancel cause)
      in
      drive (Eval (Eff eff)) [])

let run_now : type a err. context -> (a, err) t -> (a, err) Exit.t option =
 fun context eff ->
  let result : (a, err) Exit.t option ref = ref None in
  let state = ref (Eval (Eff eff)) in
  let stack = ref [] in
  let stopped = ref false in
  let finish (exit : (Obj.t, Obj.t) Exit.t) =
    result := Some (Obj.magic exit);
    stopped := true
  in
  while not !stopped do
    match !state with
    | Eval (Eff eff) -> (
        match eff with
        | Pure value -> state := Success (Obj.repr value)
        | Fail err -> state := Error (Cause.fail (Obj.repr err))
        | Sync f -> (
            try state := Success (Obj.repr (f ()))
            with exn -> state := Error (erased_die exn))
        | Yield -> stopped := true
        | Check -> (
            match Runtime_fiber.cancel_cause context.fiber with
            | Some cause when Runtime_fiber.interruptible context.fiber ->
                state := Error cause
            | _ -> state := Success (Obj.repr ()))
        | Async _ -> stopped := true
        | Uninterruptible { inner } ->
            let was_interruptible =
              Runtime_fiber.interruptible context.fiber
            in
            Runtime_fiber.set_interruptible context.fiber false;
            stack :=
              Uninterruptible_frame was_interruptible :: !stack;
            state := Eval (Eff inner)
        | Map { inner; f } ->
            stack :=
              Map_frame (fun value -> Obj.repr (f (Obj.obj value))) :: !stack;
            state := Eval (Eff inner)
        | Bind { inner; k } ->
            stack := Bind_frame (fun value -> Eff (k (Obj.obj value))) :: !stack;
            state := Eval (Eff inner)
        | Catch { inner; handler } ->
            stack :=
              Catch_frame (fun err -> Eff (handler (Obj.obj err))) :: !stack;
            state := Eval (Eff inner)
        | Map_error { inner; f } ->
            stack :=
              Map_error_frame (fun err -> Obj.repr (f (Obj.obj err))) :: !stack;
            state := Eval (Eff inner)
        | Finally { inner; cleanup } ->
            stack := Finally_frame (Eff cleanup) :: !stack;
            state := Eval (Eff inner))
    | Success value -> (
        match !stack with
        | [] -> finish (Exit.Ok value)
        | frame :: rest -> (
            stack := rest;
            match frame with
            | Map_frame f -> (
                try state := Success (f value)
                with exn -> state := Error (erased_die exn))
            | Bind_frame k -> (
                try state := Eval (k value)
                with exn -> state := Error (erased_die exn))
            | Catch_frame _ | Map_error_frame _ -> state := Success value
            | Uninterruptible_frame was_interruptible ->
                Runtime_fiber.set_interruptible context.fiber
                  was_interruptible
            | Finally_frame cleanup ->
                stack := Finalizer_success_frame value :: !stack;
                state := Eval cleanup
            | Finalizer_success_frame original -> state := Success original
            | Finalizer_error_frame primary -> state := Error primary))
    | Error cause -> (
        match !stack with
        | [] -> finish (Exit.Error cause)
        | frame :: rest -> (
            stack := rest;
            match frame with
            | Map_frame _ | Bind_frame _ -> state := Error cause
            | Catch_frame handler -> (
                match cause with
                | Cause.Fail err -> (
                    try state := Eval (handler err)
                    with exn -> state := Error (erased_die exn))
                | Cause.Die _ | Interrupt _ | Sequential _ | Concurrent _
                | Finalizer _ | Suppressed _ ->
                    state := Error cause)
            | Map_error_frame f -> (
                try state := Error (Cause.map f cause)
                with exn -> state := Error (erased_die exn))
            | Uninterruptible_frame was_interruptible ->
                Runtime_fiber.set_interruptible context.fiber
                  was_interruptible
            | Finally_frame cleanup ->
                stack := Finalizer_error_frame cause :: !stack;
                state := Eval cleanup
            | Finalizer_success_frame _ ->
                state := Error (Cause.finalizer (finalizer_cause cause))
            | Finalizer_error_frame primary ->
                state :=
                  Error
                    (Cause.suppressed ~primary
                       ~finalizer:(finalizer_cause cause))))
  done;
  !result
