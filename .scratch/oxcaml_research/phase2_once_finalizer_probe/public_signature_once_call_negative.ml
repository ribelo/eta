(* Candidate A call-site property: a public acquire_release parameter annotated
   as [@ once] rejects a release callback that is explicitly called twice. *)

type ('env, 'err, 'a) t = Pure : 'a -> ('env, 'err, 'a) t

let acquire_release ~acquire:_ ~(release @ once) =
  let resource = 1 in
  ignore (release resource);
  ignore (release resource);
  Pure resource

let () =
  let (release @ once) _ = Pure () in
  ignore (acquire_release ~acquire:(Pure 1) ~release)
