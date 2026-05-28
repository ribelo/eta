open! Portable

module PA = Portable.Atomic

let with_resource ~acquire ~release body =
  let open Eta.Syntax in
  let* resource = Eta.Effect.acquire_release ~acquire ~release in
  body resource

let slot : ((int, [ `Boom ]) Eta.Effect.t option) PA.t = PA.make None

let publish_with_resource_effect () =
  let effect =
    with_resource
      ~acquire:(Eta.Effect.pure 1)
      ~release:(fun _ -> Eta.Effect.unit)
      (fun resource -> Eta.Effect.pure resource)
  in
  let old = PA.get slot in
  ignore (PA.compare_and_set slot ~if_phys_equal_to:old ~replace_with:(Some effect));
  let domain =
    Domain.Safe.spawn (fun () ->
        match PA.get slot with None -> () | Some effect -> ignore effect)
  in
  Domain.join domain
