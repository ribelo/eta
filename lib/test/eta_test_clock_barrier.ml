let after_movement_claim = Atomic.make (fun () -> ())

let run_after_movement_claim () =
  (Atomic.get after_movement_claim) ()

let set_after_movement_claim hook =
  Atomic.exchange after_movement_claim hook
