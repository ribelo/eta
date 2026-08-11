let before_admission = Atomic.make (fun () -> ())
let after_admission = Atomic.make (fun () -> ())

let set_before_admission hook =
  Atomic.exchange before_admission hook

let set_after_admission hook =
  Atomic.exchange after_admission hook

let run_before_admission () =
  (Atomic.get before_admission) ()

let run_after_admission () =
  (Atomic.get after_admission) ()
