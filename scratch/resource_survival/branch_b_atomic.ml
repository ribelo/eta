open Effet

type ('env, 'err, 'a) t = {
  load : ('env, 'err, 'a) Effect.t;
  cell : 'a option Atomic.t;
  failures : 'err Cause.t list Atomic.t;
}

let remember resource value =
  Atomic.set resource.cell (Some value);
  value

let refresh resource =
  resource.load |> Effect.map (fun value -> ignore (remember resource value))

let get resource =
  match Atomic.get resource.cell with
  | Some value -> Effect.pure value
  | None -> resource.load |> Effect.map (remember resource)

let manual load =
  load
  |> Effect.map (fun value ->
         { load; cell = Atomic.make (Some value); failures = Atomic.make [] })

let push_failure resource cause =
  let rec loop () =
    let current = Atomic.get resource.failures in
    if not (Atomic.compare_and_set resource.failures current (cause :: current))
    then loop ()
  in
  loop ()

let failures resource =
  Effect.sync "atomic_resource.failures" (fun _ ->
      List.rev (Atomic.get resource.failures))

let auto ?on_error ~load ~schedule () =
  let rec refresh_loop resource step =
    match Schedule.next_delay schedule ~step with
    | None -> Effect.unit
    | Some delay ->
        let refresh_once =
          refresh resource
          |> Effect.catch (fun err ->
                 Effect.sync "atomic_resource.auto.refresh_failed" (fun _ ->
                     push_failure resource (Cause.Fail err);
                     Option.iter (fun f -> f err) on_error))
        in
        refresh_once
        |> Effect.delay delay
        |> Effect.bind (fun () -> refresh_loop resource (step + 1))
  in
  load
  |> Effect.map (fun value ->
         { load; cell = Atomic.make (Some value); failures = Atomic.make [] })
  |> Effect.bind (fun resource ->
         (* This is the crucial Branch B cost after public detach was removed:
            an equivalent auto-refresh recipe needs the internal daemon node. *)
         Effect.Private.daemon (refresh_loop resource 0)
         |> Effect.map (fun () -> resource))
