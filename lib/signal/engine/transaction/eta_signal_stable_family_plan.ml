type counters = {
  mutable enabled : bool;
  mutable input_comparisons : int;
  mutable diff_events : int;
  mutable selected_child_visits : int;
  mutable provisional_additions : int;
  mutable commits : int;
  mutable discards : int;
}

type counter_snapshot = {
  input_comparisons : int;
  diff_events : int;
  selected_child_visits : int;
  provisional_additions : int;
  commits : int;
  discards : int;
}

let create_counters () =
  {
    enabled = false;
    input_comparisons = 0;
    diff_events = 0;
    selected_child_visits = 0;
    provisional_additions = 0;
    commits = 0;
    discards = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.input_comparisons <- 0;
  counters.diff_events <- 0;
  counters.selected_child_visits <- 0;
  counters.provisional_additions <- 0;
  counters.commits <- 0;
  counters.discards <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    input_comparisons = counters.input_comparisons;
    diff_events = counters.diff_events;
    selected_child_visits = counters.selected_child_visits;
    provisional_additions = counters.provisional_additions;
    commits = counters.commits;
    discards = counters.discards;
  }

let succ value = if value = max_int then max_int else value + 1

let note_input_comparison counters =
  if counters.enabled then
    counters.input_comparisons <- succ counters.input_comparisons

let note_diff_event counters =
  if counters.enabled then counters.diff_events <- succ counters.diff_events

let note_selected_child_visit counters =
  if counters.enabled then
    counters.selected_child_visits <- succ counters.selected_child_visits

let note_provisional_addition counters =
  if counters.enabled then
    counters.provisional_additions <- succ counters.provisional_additions

let note_commit counters =
  if counters.enabled then counters.commits <- succ counters.commits

let note_discard counters =
  if counters.enabled then counters.discards <- succ counters.discards
