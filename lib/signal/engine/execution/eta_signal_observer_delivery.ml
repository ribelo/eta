type counters = {
  mutable enabled : bool;
  mutable lifecycle_checks : int;
  mutable callback_attempts : int;
  mutable acknowledgement_attempts : int;
  mutable acknowledgement_successes : int;
  mutable releases : int;
  mutable terminal_skips : int;
}

type counter_snapshot = {
  lifecycle_checks : int;
  callback_attempts : int;
  acknowledgement_attempts : int;
  acknowledgement_successes : int;
  releases : int;
  terminal_skips : int;
}

let create_counters () =
  {
    enabled = false;
    lifecycle_checks = 0;
    callback_attempts = 0;
    acknowledgement_attempts = 0;
    acknowledgement_successes = 0;
    releases = 0;
    terminal_skips = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.lifecycle_checks <- 0;
  counters.callback_attempts <- 0;
  counters.acknowledgement_attempts <- 0;
  counters.acknowledgement_successes <- 0;
  counters.releases <- 0;
  counters.terminal_skips <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    lifecycle_checks = counters.lifecycle_checks;
    callback_attempts = counters.callback_attempts;
    acknowledgement_attempts = counters.acknowledgement_attempts;
    acknowledgement_successes = counters.acknowledgement_successes;
    releases = counters.releases;
    terminal_skips = counters.terminal_skips;
  }

let succ value = if value = max_int then max_int else value + 1

let note_lifecycle_check counters =
  if counters.enabled then
    counters.lifecycle_checks <- succ counters.lifecycle_checks

let note_callback_attempt counters =
  if counters.enabled then
    counters.callback_attempts <- succ counters.callback_attempts

let note_acknowledgement_attempt counters =
  if counters.enabled then
    counters.acknowledgement_attempts <-
      succ counters.acknowledgement_attempts

let note_acknowledgement_success counters =
  if counters.enabled then
    counters.acknowledgement_successes <-
      succ counters.acknowledgement_successes

let note_release counters =
  if counters.enabled then counters.releases <- succ counters.releases

let note_terminal_skip counters =
  if counters.enabled then
    counters.terminal_skips <- succ counters.terminal_skips

type ('event, 'callback, 'error) runner = {
  activate_and_claim : 'event -> (bool, 'error) Eta.Effect.t;
  after_claim : unit -> (unit, 'error) Eta.Effect.t;
  construct : 'event -> ('callback option, 'error) Eta.Effect.t;
  run_callback : 'event -> 'callback -> (unit, 'error) Eta.Effect.t;
  acknowledge : 'event -> (unit, 'error) Eta.Effect.t;
  finish_error : 'event -> delivered:bool -> (unit, 'error) Eta.Effect.t;
}

let create ~activate_and_claim ~after_claim ~construct ~run_callback
    ~acknowledge ~finish_error =
  {
    activate_and_claim;
    after_claim;
    construct;
    run_callback;
    acknowledge;
    finish_error;
  }

let run_claimed runner event =
  let open Eta.Syntax in
  let delivered = ref false in
  let delivery =
    let* () = runner.after_claim () in
    let* callback = runner.construct event in
    match callback with
    | None -> Eta.Effect.unit
    | Some callback ->
        let* () = runner.run_callback event callback in
        delivered := true;
        runner.acknowledge event
  in
  Eta.Effect.on_exit
    (function
      | Eta.Exit.Ok _ -> Eta.Effect.unit
      | Eta.Exit.Error _ -> runner.finish_error event ~delivered:!delivered)
    delivery

let rec run runner = function
  | [] -> Eta.Effect.unit
  | event :: rest ->
      let open Eta.Syntax in
      let* claimed = runner.activate_and_claim event in
      if not claimed then run runner rest
      else
        let* () = run_claimed runner event in
        run runner rest
