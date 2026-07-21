open Eta

let boom = Failure "intercept failed"

let effect =
  Effect.intercept_log (fun _record -> raise boom)
    (Effect.log "never reaches the sink")

(* Runtime execution produces [Exit.Error (Cause.Die die)] with
   [die.exn == boom]. This is ordinary defect capture, not a typed failure and
   not a swallowed log. *)
