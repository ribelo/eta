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
  let rec refresh_loop resource driver =
    match Schedule.next driver with
    | None -> Effect.unit
    | Some (delay, driver') ->
        let refresh_once =
          refresh resource
          |> Effect.catch (fun err ->
                 Effect.named "resource.auto.refresh_failed" (Effect.sync (fun () ->
                     resource.failures := Cause.Fail err :: !(resource.failures);
                     Option.iter (fun f -> f err) on_error)))
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
