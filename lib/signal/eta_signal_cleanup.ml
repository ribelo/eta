type hook = unit -> unit

let fail_hooks causes =
  let cause =
    match causes with
    | [] -> invalid_arg "Eta_signal_cleanup.fail_hooks: empty causes"
    | [ cause ] -> cause
    | causes -> Eta.Cause.sequential causes
  in
  Eta.Effect.Expert.make ~capabilities:[] ~leaf_name:"Eta_signal_cleanup.run_hooks" (fun _ ->
      Eta.Exit.Error cause)

let run_hooks hooks =
  let rec loop failures = function
    | [] -> (
        match List.rev failures with
        | [] -> Eta.Effect.unit
        | causes -> fail_hooks causes)
    | hook :: rest ->
        Eta.Effect.to_exit (Eta.Effect.sync hook)
        |> Eta.Effect.bind (function
             | Eta.Exit.Ok () -> loop failures rest
             | Eta.Exit.Error cause -> loop (cause :: failures) rest)
  in
  loop [] hooks

let run_as_finalizers hooks =
  Eta.Effect.unit |> Eta.Effect.on_exit (fun _exit -> run_hooks hooks)

let run_pending_as_finalizers hooks_ref =
  match !hooks_ref with
  | [] -> Eta.Effect.unit
  | hooks ->
      run_as_finalizers hooks
      |> Eta.Effect.on_exit (fun _exit ->
             Eta.Effect.sync (fun () -> hooks_ref := []))

let fail_with_pending hooks_ref eff =
  eff
  |> Eta.Effect.on_exit (fun _exit -> run_pending_as_finalizers hooks_ref)

let run_pending hooks_ref =
  match !hooks_ref with
  | [] -> Eta.Effect.unit
  | hooks ->
      run_hooks hooks
      |> Eta.Effect.on_exit (fun _exit ->
             Eta.Effect.sync (fun () -> hooks_ref := []))

let pending hooks_ref =
  match !hooks_ref with
  | [] -> false
  | _ :: _ -> true
