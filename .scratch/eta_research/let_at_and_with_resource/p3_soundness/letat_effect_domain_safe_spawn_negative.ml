let with_resource ~acquire ~release body =
  let open Eta.Syntax in
  let* resource = Eta.Effect.acquire_release ~acquire ~release in
  body resource

let capture_letat_effect () =
  let ( let@ ) f k = f k in
  let effect =
    let@ resource =
      with_resource ~acquire:(Eta.Effect.pure 1) ~release:(fun _ -> Eta.Effect.unit)
    in
    Eta.Effect.pure resource
  in
  let domain = Domain.Safe.spawn (fun () -> ignore effect) in
  Domain.join domain
