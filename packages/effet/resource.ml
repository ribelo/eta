type ('env, 'err, 'a) t = {
  load : ('env, 'err, 'a) Effect.t;
  mutable value : 'a option;
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
  load |> Effect.map (fun value -> { load; value = Some value })

let auto ?on_error ~load ~schedule () =
  let rec refresh_loop resource step =
    match Schedule.next_delay schedule ~step with
    | None -> Effect.unit
    | Some delay ->
        let refresh_once =
          refresh resource
          |> Effect.catch (fun err ->
                 Effect.sync "resource.auto.refresh_failed" (fun _ ->
                     Option.iter (fun f -> f err) on_error))
        in
        refresh_once
        |> Effect.delay delay
        |> Effect.bind (fun () -> refresh_loop resource (step + 1))
  in
  load
  |> Effect.map (fun value -> { load; value = Some value })
  |> Effect.bind (fun resource ->
         Effect.detach (refresh_loop resource 0)
         |> Effect.map (fun () -> resource))
