(* Candidate B: accept a [once] release at construction and hide it behind a
   regular closure in the reusable AST. This would preserve the old AST shape if
   OxCaml allowed it, but it would be unsound because the wrapper is many. *)

type ('env, 'err, 'a) t =
  | Pure : 'a -> ('env, 'err, 'a) t
  | Acquire_release :
      ('env, 'err, 'a) t * ('a -> ('env, 'err, unit) t)
      -> ('env, 'err, 'a) t

let acquire_release ~acquire ~(release @ once) =
  Acquire_release (acquire, fun value -> release value)

let () =
  let (release @ once) _ = Pure () in
  ignore (acquire_release ~acquire:(Pure 1) ~release)
