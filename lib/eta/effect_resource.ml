(** Effect lifecycle: finalizers, [acquire_release], [scoped]. Internal: see
    Effect for the public surface. *)

open Effect_core

let run_cleanup_to_exit frame cleanup =
  Runtime_core.cancel_protect @@ fun () ->
  let cleanup_finalizers = ref [] in
  let cleanup_frame = { frame with finalizers = cleanup_finalizers } in
  try
    ok
      (Runtime_core.with_finalizers ~runtime:frame.runtime ~fail_key:frame.fail_key
         cleanup_finalizers (fun () -> run_to_value cleanup_frame cleanup))
  with exn -> exit_of_exn cleanup_frame exn

let finally cleanup effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  match run_to_exit frame effect with
  | Exit.Ok value -> (
      match run_cleanup_to_exit frame cleanup with
      | Exit.Ok () -> ok value
      | Exit.Error cause -> error cause)
  | Exit.Error primary -> (
      match run_cleanup_to_exit frame cleanup with
      | Exit.Ok () -> error primary
      | Exit.Error finalizer -> error (Cause.suppressed ~primary ~finalizer))

let acquire_release ~acquire ~release =
  preserve acquire @@ fun () ->
  let frame = current_frame () in
  match acquire.eval () with
  | Exit.Error _ as err -> err
  | Exit.Ok value ->
      frame.finalizers :=
        (fun () ->
          let release_finalizers = ref [] in
          let release_frame = { frame with finalizers = release_finalizers } in
          Runtime_core.with_finalizers ~runtime:frame.runtime ~fail_key:frame.fail_key
            release_finalizers (fun () -> run_to_value release_frame (release value)))
        :: !(frame.finalizers);
      ok value

let acquire_use_release ~acquire ~release body =
  acquire_release ~acquire ~release |> bind body

let scoped effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  try
    ok
      (let run_scoped sw =
         let finalizers = ref [] in
         let child_frame = { frame with sw; finalizers } in
         Runtime_core.with_finalizers ~runtime:frame.runtime ~fail_key:frame.fail_key
           finalizers (fun () -> run_to_value child_frame effect)
       in
       if Runtime_core.has_eio_fiber_context () then switch_run frame run_scoped
       else run_scoped frame.sw)
  with exn -> exit_of_exn frame exn
