type ('a, 'err) t = {
  load : ('a, 'err) Effect.t;
  mutex : Sync_lock.t;
  mutable value : 'a option;
  mutable next_version : int;
  mutable published_version : int;
  mutable failures : 'err Cause.t list;
}

let with_lock resource (f) =
  Sync_lock.use resource.mutex f

let loaded load value =
  {
    load;
    mutex = Sync_lock.create ();
    value = Some value;
    next_version = 0;
    published_version = 0;
    failures = [];
  }

let begin_load resource =
  Effect.sync (fun () ->
      with_lock resource @@ fun () ->
      resource.next_version <- resource.next_version + 1;
      resource.next_version)

let publish resource version value =
  Effect.sync (fun () ->
      with_lock resource @@ fun () ->
      if version >= resource.published_version then (
        resource.value <- Some value;
        resource.published_version <- version))

let refresh resource =
  begin_load resource
  |> Effect.bind (fun version ->
         resource.load
         |> Effect.bind (fun value -> publish resource version value))

let get resource =
  Effect.sync (fun () -> with_lock resource @@ fun () -> resource.value)
  |> Effect.bind (function
       | Some value -> Effect.pure value
       | None ->
           begin_load resource
           |> Effect.bind (fun version ->
                  resource.load
                  |> Effect.bind (fun value ->
                         publish resource version value
                         |> Effect.map (fun () -> value))))

let manual load =
  load |> Effect.map (loaded load)

let failures resource =
  Effect.named "resource.failures"
    (Effect.sync (fun () ->
         with_lock resource @@ fun () -> List.rev resource.failures))

let rec drive_schedule_step = function
  | Schedule.Complete (decision, driver) -> Effect.pure (decision, driver)
  | Schedule.Hook (hook, resume) ->
      hook |> Effect.bind (fun () -> drive_schedule_step (resume ()))

let auto ?(on_error) ~load ?random ~schedule () =
  let add_failure resource cause =
    Effect.sync (fun () ->
        with_lock resource @@ fun () ->
        resource.failures <- cause :: resource.failures)
  in
  let record_failure resource cause =
    Effect.named "resource.auto.refresh_failed"
      (add_failure resource cause
      |> Effect.bind (fun () ->
             match (cause, on_error) with
             | Cause.Fail err, Some f ->
                 Effect.sync (fun () ->
                     try f err; None
                     with exn ->
                       Some
                         (Cause.die_with_backtrace exn
                            (Printexc.get_raw_backtrace ())))
                 |> Effect.bind (function
                      | None -> Effect.unit
                      | Some defect -> add_failure resource defect)
             | _ -> Effect.unit))
  in
  let rec refresh_loop resource driver =
    Effect.now
    |> Effect.bind (fun now_ms ->
           drive_schedule_step (Schedule.step_plan ~now_ms ~input:() driver)
           |> Effect.bind (function
                | Schedule.Done _, _ -> Effect.unit
                | Schedule.Continue metadata, driver' ->
                    let refresh_once =
                      Effect.all_settled [ refresh resource ]
                      |> Effect.bind (function
                           | [ Ok () ] -> Effect.unit
                           | [ Error cause ] -> record_failure resource cause
                           | results ->
                               Effect.sync (fun () ->
                                   invalid_arg
                                     ("Eta.Resource.auto: expected one refresh result, got "
                                    ^ string_of_int (List.length results))))
                    in
                    refresh_once
                    |> Effect.delay metadata.delay
                    |> Effect.bind (fun () -> refresh_loop resource driver')))
  in
  load
  |> Effect.map (loaded load)
  |> Effect.bind (fun resource ->
         let driver = Schedule.start ?random schedule in
         Effect.daemon (refresh_loop resource driver)
         |> Effect.map (fun () -> resource))
