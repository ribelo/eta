type isolated_resource = int ref Capsule.Isolated.t

let make () =
  Capsule.Isolated.create (fun () -> ref 41)

let bump resource =
  let #(resource, _) =
    Capsule.Isolated.with_unique resource ~f:(fun cell -> cell := !cell + 1)
  in
  resource

let get resource =
  Capsule.Isolated.with_unique resource ~f:(fun cell -> !cell)

let smoke () =
  let resource = make () in
  let resource = bump resource in
  let #(_resource, { Base.Modes.Aliased.aliased = value }) = get resource in
  match value with
  | 42 -> ()
  | _ -> failwith "capsule isolated resource did not refresh"

let () = smoke ()
