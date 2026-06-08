open Effet
open! Portable

module Portable_resource = struct
  type ('err : immutable_data, 'a : immutable_data) state = {
    value : 'a option Atomic.t;
    failures : 'err Cause.t list Atomic.t;
  }

  type ('env, 'err : immutable_data, 'a : immutable_data) t = {
    load : ('env, 'err, 'a) Effect.t;
    state : ('err, 'a) state;
  }

  let make_state value =
    { value = Atomic.make value; failures = Atomic.make [] }

  let record_failure state err =
    Atomic.update state.failures ~pure_f:(fun failures ->
        Cause.Fail err :: failures)

  let make_portable_refresh state =
    let (refresh @ portable) result =
      match result with
      | Ok value -> Atomic.set state.value (Some value)
      | Error err -> record_failure state err
    in
    refresh

  let refresh resource =
    resource.load
    |> Effect.map (fun value -> Atomic.set resource.state.value (Some value))

  let get resource =
    match Atomic.get resource.state.value with
    | Some value -> Effect.pure value
    | None ->
        resource.load
        |> Effect.map (fun value ->
               Atomic.set resource.state.value (Some value);
               value)

  let failures_contended resource =
    Effect.thunk "portable_resource.failures" (fun _ ->
        { Base.Modes.Contended.contended = Atomic.get resource.state.failures })

  let manual load =
    load
    |> Effect.map (fun value ->
           { load; state = make_state (Some value) })

  let auto ?on_error ~load ~schedule () =
    let rec refresh_loop resource step =
      match Schedule.next_delay schedule ~step with
      | None -> Effect.unit
      | Some delay ->
          let refresh_once =
            refresh resource
            |> Effect.catch (fun err ->
                   Effect.thunk "portable_resource.auto.refresh_failed" (fun _ ->
                       record_failure resource.state err;
                       Option.iter (fun f -> f err) on_error))
          in
          refresh_once
          |> Effect.delay delay
          |> Effect.bind (fun () -> refresh_loop resource (step + 1))
    in
    load
    |> Effect.map (fun value -> { load; state = make_state (Some value) })
    |> Effect.bind (fun resource ->
           Effect.Private.daemon (refresh_loop resource 0)
           |> Effect.map (fun () -> resource))
end

let with_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  f rt

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let effect_smoke () =
  with_runtime @@ fun rt ->
  let program =
    Portable_resource.manual (Effect.pure 41)
    |> Effect.bind (fun resource ->
           Portable_resource.refresh resource
           |> Effect.bind (fun () ->
                  Portable_resource.get resource
                  |> Effect.bind (fun value ->
                         Portable_resource.failures_contended resource
                         |> Effect.map (fun _failures -> value))))
  in
  match Runtime.run rt program with
  | Exit.Ok 41 -> ()
  | Exit.Ok _ -> failwith "portable Effet Resource returned wrong value"
  | Exit.Error _ -> failwith "portable Effet Resource failed"

let parallel_state_smoke () =
  let state = Portable_resource.make_state None in
  let refresh = Portable_resource.make_portable_refresh state in
  with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
          let #((), ()) =
            Parallel.fork_join2
              parallel
              (fun _ -> refresh (Ok 42))
              (fun _ -> refresh (Error "refresh failed"))
          in
          ()));
  match Atomic.get state.value, Atomic.get state.failures with
  | Some 42, [ Cause.Fail "refresh failed" ] -> ()
  | _ -> failwith "portable Effet Resource state failed parallel smoke"

let () =
  effect_smoke ();
  parallel_state_smoke ()
