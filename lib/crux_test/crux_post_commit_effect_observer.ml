module Shared = Eta_crux.Testing
module Bridge = Eta_crux__Crux_testing

module Effect_id = Shared.Effect_id
module Commit_index = Shared.Commit_index
module Event_position = Shared.Event_position

type settlement = Shared.settlement =
  | Succeeded
  | Interrupted
  | Failed

type event = Shared.event =
  | Staged of {
      position : Event_position.t;
      commit : Commit_index.t;
      effects : Effect_id.t list;
    }
  | Started of {
      position : Event_position.t;
      effect : Effect_id.t;
    }
  | Settled of {
      position : Event_position.t;
      effect : Effect_id.t;
      settlement : settlement;
    }
  | Discarded_before_start of {
      position : Event_position.t;
      effect : Effect_id.t;
    }

type t = {
  observer : Bridge.observer;
  consumer_busy : bool Atomic.t;
}

let create () =
  {
    observer = Bridge.create ();
    consumer_busy = Atomic.make false;
  }

let attachment controller = controller.observer

let with_consumer controller operation =
  if
    not
      (Atomic.compare_and_set controller.consumer_busy false true)
  then
    invalid_arg
      "Eta_crux_test.Post_commit_effect_observer: concurrent consumer operation";
  Fun.protect
    ~finally:(fun () -> Atomic.set controller.consumer_busy false)
    (fun () ->
      Crux_post_commit_observer_barrier.run_after_consumer_claim ();
      operation controller.observer)

let poll controller = with_consumer controller Bridge.poll
let drain controller = with_consumer controller Bridge.drain

let expect_empty controller =
  with_consumer controller @@ fun observer ->
  if not (Bridge.is_empty observer) then
    Alcotest.fail
      "Eta_crux_test.Post_commit_effect_observer: expected no undrained events"
