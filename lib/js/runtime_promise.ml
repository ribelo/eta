type 'a waiter = {
  scheduler : Scheduler.t;
  resume : 'a -> unit;
}

type 'a state =
  | Pending of 'a waiter Stdlib.Queue.t
  | Resolved of 'a

type 'a t = { mutable state : 'a state }
type 'a resolver = 'a t

let create () =
  let promise = { state = Pending (Stdlib.Queue.create ()) } in
  (promise, promise)

let resolve resolver value =
  match resolver.state with
  | Resolved _ ->
      invalid_arg "Eta_js.Runtime_promise.resolve: already resolved"
  | Pending waiters ->
      resolver.state <- Resolved value;
      Stdlib.Queue.iter
        (fun waiter ->
          Scheduler.enqueue waiter.scheduler (fun () -> waiter.resume value))
        waiters

let await promise ~scheduler resume =
  match promise.state with
  | Resolved value -> Scheduler.enqueue scheduler (fun () -> resume value)
  | Pending waiters -> Stdlib.Queue.add { scheduler; resume } waiters

let peek promise =
  match promise.state with
  | Resolved value -> Some value
  | Pending _ -> None
