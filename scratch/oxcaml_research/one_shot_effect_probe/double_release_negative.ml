(* A once release callback cannot be called twice by a resource interpreter. *)

type ('env, 'err, 'a) t = 'env -> ('a, 'err) result

let pure value _env = Ok value

let acquire_release ~(acquire @ once) ~(release @ once) env =
  match acquire env with
  | Error err -> Error err
  | Ok resource ->
      ignore (release resource env);
      release resource env

let () =
  let (release @ once) _resource _env = Ok () in
  ignore (acquire_release ~acquire:(pure 1) ~release ())
