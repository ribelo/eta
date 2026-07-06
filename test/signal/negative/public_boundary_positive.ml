module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp ppf = function
    | `Observer_failed -> Format.pp_print_string ppf "observer failed"
end

module A = Eta_signal.Make (Observer_error) ()
module B = Eta_signal.Make (Observer_error) ()

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
  A.bind (A.const true) (fun active ->
      if active then A.const 1 else A.const 0)

let _observe =
  A.Observer.observe a_signal (fun _update -> Eta.Effect.unit)

let _read
    (observer : int A.Observer.t) :
    (int, A.observer_read_error) Eta.Effect.t =
  A.Observer.read observer

let _dispose observer = A.Observer.dispose observer
let _stream = A.Stream.observe a_signal
let _stats () = A.stats ()

let _now :
    (A.Time.monotonic_time A.signal, A.time_error) Eta.Effect.t =
  A.Time.now ~every:(Eta.Duration.ms 1) ()
