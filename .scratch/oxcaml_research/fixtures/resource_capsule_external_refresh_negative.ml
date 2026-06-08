type isolated_resource = int ref Capsule.Isolated.t

let make () =
  Capsule.Isolated.create (fun () -> ref 0)

let refresh resource value =
  let #(resource, _) =
    Capsule.Isolated.with_unique resource ~f:(fun cell -> cell := value)
  in
  resource

let () =
  let resource = make () in
  ignore (refresh resource 42)

