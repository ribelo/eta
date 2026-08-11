let after_lock : (unit -> unit) Atomic.t =
  Atomic.make (fun () -> ())

let set_after_lock hook = Atomic.exchange after_lock hook
let run_after_lock () = (Atomic.get after_lock) ()
