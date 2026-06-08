(* Runtime.run consumes a resource-owning one-shot effect. Reusing the same
   program would reuse its once release callback. *)

type ('env, 'err, 'a) t = 'env -> ('a, 'err) result

let pure value _env = Ok value

let acquire_release ~(acquire @ once) ~(release @ once) env =
  match acquire env with
  | Error err -> Error err
  | Ok resource -> (
      match release resource env with
      | Ok () -> Ok resource
      | Error err -> Error err)

let run (effect @ once) env = effect env

let () =
  let (release @ once) _resource _env = Ok () in
  let program = acquire_release ~acquire:(pure 1) ~release in
  ignore (run program ());
  ignore (run program ())
