open! Portable

module PA = Portable.Atomic

let slot : ((int, [ `Boom ]) Eta.Effect.t option) PA.t = PA.make None

let store_effect (effect : (int, [ `Boom ]) Eta.Effect.t) =
  let old = PA.get slot in
  let replace_with = Some effect in
  ignore (PA.compare_and_set slot ~if_phys_equal_to:old ~replace_with);
  let domain =
    Domain.Safe.spawn (fun () ->
        match PA.get slot with None -> () | Some effect -> ignore effect)
  in
  Domain.join domain
