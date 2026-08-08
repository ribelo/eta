module A = Eta_signal.Make_no_error ()
module A_stream = Eta_signal_stream.Make (A)
module B = Eta_signal.Make_no_error ()

let a_source = A.Var.create 1
let b_source = B.Var.create 1
let a_signal = A.Var.watch a_source
let _b_signal = B.Var.watch b_source |> B.map (fun value -> value + 1)

let _mapped : int A.signal = A.map (fun value -> value + 1) a_signal
let _set_source () = A.Var.set a_source 2

let _map9 =
  A.map9
    (fun a b c d e f g h i -> a + b + c + d + e + f + g + h + i)
    a_signal a_signal a_signal a_signal a_signal a_signal a_signal a_signal
    a_signal

let _bind =
  A.bind (A.const true) ~f:(fun active ->
      if active then A.const 1 else A.const 0)

let _observe =
  A.Observer.observe a_signal ~on_update:(fun _update -> Ok ())

let _read
    (observer : int A.Observer.t) :
    (int, A.observer_read_error) result =
  A.Observer.read observer

let _dispose observer = A.Observer.dispose observer
let _stream = A_stream.observe a_signal
let _stats () = A.stats ()

let _now :
    (A.Time.monotonic_time A.signal, A.time_error) Eta.Effect.t =
  A.Time.now ~every:(Eta.Duration.ms 1)
