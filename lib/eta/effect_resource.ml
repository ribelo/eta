(** Effect lifecycle: finalizers, [acquire_release], [scoped]. Internal: see
    Effect for the public surface. *)

open Effect_core

let run_cleanup frame cleanup =
  try
    frame.runtime.contract.Runtime_contract.protect @@ fun () ->
    match run_scope frame (cleanup ()) with
    | Exit.Ok () -> None
    | Exit.Error cause -> Some (render_cause_error frame cause)
  with exn ->
    Some
      (render_cause_error frame
         (Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn))

let finish_with_cleanup frame cleanup exit =
  match run_cleanup frame (fun () -> cleanup exit) with
  | None -> exit
  | Some finalizer -> (
      match exit with
      | Exit.Ok _ -> error (Cause.finalizer finalizer)
      | Exit.Error primary -> error (Cause.suppressed ~primary ~finalizer))

let on_exit cleanup eff =
  preserve eff @@ fun frame ->
  try
    finish_with_cleanup frame cleanup (run_to_exit frame eff)
  with
  | exn when Runtime_core.is_cancellation frame.runtime.contract exn -> (
      let reason =
        match Runtime_core.cancellation_reason frame.runtime.contract exn with
        | Some reason -> reason
        | None -> assert false
      in
      let primary = frame.interrupt_of_cancel reason in
      match run_cleanup frame (fun () -> cleanup (Exit.Error primary)) with
      | None -> raise exn
      | Some finalizer -> error (Cause.suppressed ~primary ~finalizer))
  | exn ->
      finish_with_cleanup frame cleanup (exit_of_exn frame exn)

let finally cleanup eff =
  on_exit (fun _ -> cleanup) eff

let acquire_release ~acquire ~(release) =
  preserve acquire @@ fun frame ->
  match eval frame acquire with
  | Exit.Error _ as err -> err
  | Exit.Ok value ->
      frame.finalizers :=
        (fun () ->
          run_scope_value frame (release value))
        :: !(frame.finalizers);
      ok value

let scoped eff =
  preserve eff @@ fun frame ->
  try
    ok
      (let run_scoped sw =
         run_scope_value ~sw frame eff
       in
    switch_run frame run_scoped)
  with exn -> exit_of_exn frame exn

let acquire_use_release ~acquire ~(release) (body) =
  scoped (acquire_release ~acquire ~release |> bind body)

let with_resource ~acquire ~release body =
  acquire_use_release ~acquire ~release body

let acquire_use_release_exit ~acquire ~(release) (body) =
  scoped
    (bind
       (fun resource ->
         scoped (body resource)
         |> on_exit (fun exit -> release resource exit))
       acquire)

let with_resource_exit ~acquire ~release body =
  acquire_use_release_exit ~acquire ~release body
