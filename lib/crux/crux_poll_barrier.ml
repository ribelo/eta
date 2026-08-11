let before_order_claim : (int64 ref -> unit) Atomic.t =
  Atomic.make (fun _ -> ())

let before_completion_admission = Atomic.make (fun () -> ())
let after_completion_admission = Atomic.make (fun () -> ())

let set_before_order_claim hook =
  Atomic.exchange before_order_claim hook

let run_before_order_claim order =
  (Atomic.get before_order_claim) order

let set_before_completion_admission hook =
  Atomic.exchange before_completion_admission hook

let set_after_completion_admission hook =
  Atomic.exchange after_completion_admission hook

let run_before_completion_admission () =
  (Atomic.get before_completion_admission) ()

let run_after_completion_admission () =
  (Atomic.get after_completion_admission) ()
