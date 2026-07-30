open Eta

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
  Eta_observability.named "refreshable.failures"
    (Effect.sync (fun () ->
         with_lock resource @@ fun () -> List.rev resource.failures))

let with_auto_impl on_refresh_error ~load ~schedule body =
  let add_failure resource cause =
    Effect.sync (fun () ->
        with_lock resource @@ fun () ->
        resource.failures <- cause :: resource.failures)
  in
  let record_failure resource cause =
    Eta_observability.named "refreshable.with_auto.refresh_failed"
      (add_failure resource cause
      |> Effect.bind (fun () ->
             match (cause, on_refresh_error) with
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
  let refresh_once resource =
    Effect.all_settled [ refresh resource ]
    |> Effect.bind (function
         | [ Ok () ] -> Effect.unit
         | [ Error cause ] -> record_failure resource cause
         | results ->
             Effect.sync (fun () ->
                 invalid_arg
                   ("Eta_cache.Refreshable.with_auto: expected one refresh result, got "
                  ^ string_of_int (List.length results))))
  in
  let refresh_loop resource =
    let first = ref true in
    let iteration =
      Effect.sync (fun () ->
          if !first then (
            first := false;
            false)
          else true)
      |> Effect.bind (function
           | false -> Effect.unit
           | true -> refresh_once resource)
    in
    Effect.repeat ~schedule iteration |> Effect.map (fun _ -> ())
  in
  load
  |> Effect.map (loaded load)
  |> Effect.bind (fun resource ->
         Effect.with_supervised_background
           ~name:"refreshable.with_auto"
           (refresh_loop resource)
           (fun () -> body resource))

let with_auto ~load ~schedule body =
  with_auto_impl None ~load ~schedule body

let with_auto_on_refresh_error ~on_refresh_error ~load ~schedule body =
  with_auto_impl (Some on_refresh_error) ~load ~schedule body
