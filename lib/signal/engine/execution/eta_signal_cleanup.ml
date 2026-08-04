type hook = unit -> unit

type counters = {
  mutable enabled : bool;
  mutable resource_registrations : int;
  mutable terminal_transitions : int;
  mutable hook_attempts : int;
  mutable hook_completions : int;
  mutable duplicate_transition_rejections : int;
}

type counter_snapshot = {
  resource_registrations : int;
  terminal_transitions : int;
  hook_attempts : int;
  hook_completions : int;
  duplicate_transition_rejections : int;
}

let create_counters () =
  {
    enabled = false;
    resource_registrations = 0;
    terminal_transitions = 0;
    hook_attempts = 0;
    hook_completions = 0;
    duplicate_transition_rejections = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.resource_registrations <- 0;
  counters.terminal_transitions <- 0;
  counters.hook_attempts <- 0;
  counters.hook_completions <- 0;
  counters.duplicate_transition_rejections <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    resource_registrations = counters.resource_registrations;
    terminal_transitions = counters.terminal_transitions;
    hook_attempts = counters.hook_attempts;
    hook_completions = counters.hook_completions;
    duplicate_transition_rejections =
      counters.duplicate_transition_rejections;
  }

let succ value = if value = max_int then max_int else value + 1

let note_resource_registration counters =
  if counters.enabled then
    counters.resource_registrations <- succ counters.resource_registrations

let note_terminal_transition counters =
  if counters.enabled then
    counters.terminal_transitions <- succ counters.terminal_transitions

let note_hook_attempt counters =
  if counters.enabled then counters.hook_attempts <- succ counters.hook_attempts

let note_hook_completion counters =
  if counters.enabled then
    counters.hook_completions <- succ counters.hook_completions

let note_duplicate_transition_rejection counters =
  if counters.enabled then
    counters.duplicate_transition_rejections <-
      succ counters.duplicate_transition_rejections

type disposition =
  | Committed
  | Discarded

type resource_state =
  | Pending
  | Terminal of disposition

type resource = {
  cleanup : hook;
  mutable state : resource_state;
}

type ledger = {
  counters : counters;
  mutable resources : resource list;
}

let create_ledger counters = { counters; resources = [] }

let register ledger cleanup =
  let resource = { cleanup; state = Pending } in
  ledger.resources <- resource :: ledger.resources;
  note_resource_registration ledger.counters;
  resource

let transition ledger resource disposition =
  match resource.state with
  | Terminal _ ->
      note_duplicate_transition_rejection ledger.counters;
      Error `Already_terminal
  | Pending ->
      resource.state <- Terminal disposition;
      note_terminal_transition ledger.counters;
      Ok
        (match disposition with
        | Committed -> None
        | Discarded -> Some resource.cleanup)

let pending_resources ledger =
  List.fold_left
    (fun count resource ->
      match resource.state with
      | Pending -> count + 1
      | Terminal _ -> count)
    0 ledger.resources

let fail_hooks causes =
  let cause =
    match causes with
    | [] -> invalid_arg "Eta_signal_cleanup.fail_hooks: empty causes"
    | [ cause ] -> cause
    | causes -> Eta.Cause.sequential causes
  in
  Eta.Spi.Expert.make ~leaf_name:"Eta_signal_cleanup.run_hooks" (fun _ ->
      Eta.Exit.Error cause)

let run_hooks hooks =
  let rec loop failures = function
    | [] -> (
        match List.rev failures with
        | [] -> Eta.Effect.unit
        | causes -> fail_hooks causes)
    | hook :: rest ->
        Eta.Effect.to_exit (Eta.Effect.sync hook)
        |> Eta.Effect.bind (function
             | Eta.Exit.Ok () -> loop failures rest
             | Eta.Exit.Error cause -> loop (cause :: failures) rest)
  in
  loop [] hooks

let run_as_finalizers hooks =
  Eta.Effect.unit |> Eta.Effect.on_exit (fun _exit -> run_hooks hooks)

let run_pending_as_finalizers hooks_ref =
  match !hooks_ref with
  | [] -> Eta.Effect.unit
  | hooks ->
      run_as_finalizers hooks
      |> Eta.Effect.on_exit (fun _exit ->
             Eta.Effect.sync (fun () -> hooks_ref := []))

let fail_with_pending hooks_ref eff =
  eff
  |> Eta.Effect.on_exit (fun _exit -> run_pending_as_finalizers hooks_ref)

let run_pending hooks_ref =
  match !hooks_ref with
  | [] -> Eta.Effect.unit
  | hooks ->
      run_hooks hooks
      |> Eta.Effect.on_exit (fun _exit ->
             Eta.Effect.sync (fun () -> hooks_ref := []))

let pending hooks_ref =
  match !hooks_ref with
  | [] -> false
  | _ :: _ -> true
