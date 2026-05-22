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
  Effect.sync "resource.failures" (fun () -> List.rev !(resource.failures))

let auto ?on_error ~load ?random ~schedule () =
  let rec refresh_loop resource step =
    match Schedule.next_delay ?random schedule ~step with
    | None -> Effect.unit
    | Some delay ->
        let refresh_once =
          refresh resource
          |> Effect.catch (fun err ->
                 Effect.sync "resource.auto.refresh_failed" (fun () ->
                     resource.failures := Cause.Fail err :: !(resource.failures);
                     Option.iter (fun f -> f err) on_error))
        in
        refresh_once
        |> Effect.delay delay
        |> Effect.bind (fun () -> refresh_loop resource (step + 1))
  in
  load
  |> Effect.map (fun value -> { load; value = Some value; failures = ref [] })
  |> Effect.bind (fun resource ->
         Effect.Private.daemon (refresh_loop resource 0)
         |> Effect.map (fun () -> resource))
