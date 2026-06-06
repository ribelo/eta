(** Effect lifecycle: finalizers, [acquire_release], [scoped]. Internal: see
    Effect for the public surface. *)

open Effect_core

let finally cleanup eff =
  preserve eff @@ fun () ->
  let frame = current_frame () in
  try
    let finalizers = ref [ (fun () -> run_scope_value frame cleanup) ] in
    ok
      (Runtime_core.with_finalizers ~runtime:frame.runtime
         ~fail_key:frame.fail_key ~error_renderer:frame.error_renderer finalizers
         (fun () -> run_to_value frame eff))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> exit_of_exn frame exn

let acquire_release ~acquire ~(release) =
  preserve acquire @@ fun () ->
  let frame = current_frame () in
  match eval acquire with
  | Exit.Error _ as err -> err
  | Exit.Ok value ->
      frame.finalizers :=
        (fun () ->
          run_scope_value frame (release value))
        :: !(frame.finalizers);
      ok value

let scoped eff =
  preserve eff @@ fun () ->
  let frame = current_frame () in
  try
    ok
      (let run_scoped sw =
         run_scope_value ~sw frame eff
       in
    switch_run frame run_scoped)
  with exn -> exit_of_exn frame exn

let acquire_use_release ~acquire ~(release) (body) =
  scoped (acquire_release ~acquire ~release |> bind body)
