type ('a, 'err) t = {
  load : ('a, 'err) Effect.t;
  mutable value : 'a option;
  mutable next_version : int;
  mutable published_version : int;
  mutable failures : 'err Cause.t list;
}

let loaded load value =
  {
    load;
    value = Some value;
    next_version = 0;
    published_version = 0;
    failures = [];
  }

let begin_load resource =
  Effect.sync (fun () ->
      resource.next_version <- resource.next_version + 1;
      resource.next_version)

let publish resource version value =
  Effect.sync (fun () ->
      if version >= resource.published_version then begin
        resource.value <- Some value;
        resource.published_version <- version
      end)

let refresh resource =
  Effect.bind
    (fun version ->
      Effect.bind
        (fun value -> publish resource version value)
        resource.load)
    (begin_load resource)

let get resource =
  Effect.bind
    (function
      | Some value -> Effect.pure value
      | None ->
          Effect.bind
            (fun version ->
              Effect.bind
                (fun value ->
                  Effect.map (fun () -> value) (publish resource version value))
                resource.load)
            (begin_load resource))
    (Effect.sync (fun () -> resource.value))

let manual load = Effect.map (loaded load) load

let failures resource =
  Effect.sync (fun () -> List.rev resource.failures)

let add_failure resource cause =
  Effect.sync (fun () -> resource.failures <- cause :: resource.failures)

let record_failure ?on_error resource cause =
  Effect.bind
    (fun () ->
      match (cause, on_error) with
      | Cause.Fail err, Some f ->
          Effect.bind
            (function
              | None -> Effect.unit
              | Some defect -> add_failure resource defect)
            (Effect.sync (fun () ->
                 try
                   f err;
                   None
                 with exn -> Some (Cause.die exn)))
      | _ -> Effect.unit)
    (add_failure resource cause)

let auto ?on_error ~load ?random ~schedule () =
  let rec refresh_loop resource driver =
    match Schedule.next driver with
    | None -> Effect.unit
    | Some (delay, next_driver) ->
        let refresh_once =
          Effect.bind
            (function
              | [ Ok () ] -> Effect.unit
              | [ Error cause ] -> record_failure ?on_error resource cause
              | results ->
                  Effect.sync (fun () ->
                      invalid_arg
                        ("Eta_js.Resource.auto: expected one refresh result, got "
                        ^ string_of_int (List.length results))))
            (Effect.all_settled [ refresh resource ])
        in
        Effect.bind
          (fun () -> refresh_loop resource next_driver)
          (Effect.delay delay refresh_once)
  in
  Effect.bind
    (fun resource ->
      let driver = Schedule.start ?random schedule in
      Effect.map (fun () -> resource) (Effect.daemon (refresh_loop resource driver)))
    (Effect.map (loaded load) load)
