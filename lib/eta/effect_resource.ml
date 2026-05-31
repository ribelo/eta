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
         ~error_renderer:cleanup_frame.error_renderer cleanup_finalizers (fun () ->
           run_to_value cleanup_frame cleanup))
  with exn -> exit_of_exn cleanup_frame exn

let finally cleanup effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  match run_to_exit frame effect with
  | Exit.Ok value -> (
      match run_cleanup_to_exit frame cleanup with
      | Exit.Ok () -> ok value
      | Exit.Error cause -> error (finalizer_cause frame cause))
  | Exit.Error primary -> (
      match run_cleanup_to_exit frame cleanup with
      | Exit.Ok () -> error primary
      | Exit.Error finalizer ->
          error
            (Cause.suppressed ~primary
               ~finalizer:(render_cause_error frame finalizer)))

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
            ~error_renderer:release_frame.error_renderer release_finalizers (fun () ->
              run_to_value release_frame (release value)))
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
           ~error_renderer:child_frame.error_renderer finalizers (fun () ->
             run_to_value child_frame effect)
       in
       switch_run frame run_scoped)
  with exn -> exit_of_exn frame exn
