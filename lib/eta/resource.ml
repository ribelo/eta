type ('a, 'err) t = {
  load : ('a, 'err) Effect.t;
  mutable value : 'a option;
  failures : 'err Cause.t list ref;
}

let refresh resource =
  resource.load
  |> Effect.map (fun value ->
         resource.value <- Some value)

let get resource =
  match resource.value with
  | Some value -> Effect.pure value
  | None ->
      resource.load
      |> Effect.map (fun value ->
             resource.value <- Some value;
             value)

let manual load =
  load |> Effect.map (fun value -> { load; value = Some value; failures = ref [] })

let failures resource =
  Effect.named "resource.failures" (Effect.sync (fun () -> List.rev !(resource.failures)))

let auto ?on_error ~load ?random ~schedule () =
  let record_failure resource cause =
    Effect.named "resource.auto.refresh_failed" (Effect.sync (fun () ->
        resource.failures := cause :: !(resource.failures);
        match (cause, on_error) with
        | Cause.Fail err, Some f -> (
            try f err with exn ->
              let defect =
                Cause.die_with_backtrace exn (Printexc.get_raw_backtrace ())
              in
              resource.failures := defect :: !(resource.failures))
        | _ -> ()))
  in
  let rec refresh_loop resource driver =
    match Schedule.next driver with
    | None -> Effect.unit
    | Some (delay, driver') ->
        let refresh_once =
          Effect.all_settled [ refresh resource ]
          |> Effect.bind (function
               | [ Ok () ] -> Effect.unit
               | [ Error cause ] -> record_failure resource cause
               | _ -> assert false)
        in
        refresh_once
        |> Effect.delay delay
        |> Effect.bind (fun () -> refresh_loop resource driver')
  in
  load
  |> Effect.map (fun value -> { load; value = Some value; failures = ref [] })
  |> Effect.bind (fun resource ->
         let driver = Schedule.start ?random schedule in
         Effect.Private.daemon (refresh_loop resource driver)
         |> Effect.map (fun () -> resource))
