type counters = {
  mutable enabled : bool;
  mutable admission_checks : int;
  mutable quiescent_returns : int;
  mutable work_class_zero_crossings : int;
}

type counter_snapshot = {
  admission_checks : int;
  quiescent_returns : int;
  work_class_zero_crossings : int;
}

let create_counters () =
  {
    enabled = false;
    admission_checks = 0;
    quiescent_returns = 0;
    work_class_zero_crossings = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.admission_checks <- 0;
  counters.quiescent_returns <- 0;
  counters.work_class_zero_crossings <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    admission_checks = counters.admission_checks;
    quiescent_returns = counters.quiescent_returns;
    work_class_zero_crossings = counters.work_class_zero_crossings;
  }

let succ value = if value = max_int then max_int else value + 1

let note_admission_check counters =
  if counters.enabled then
    counters.admission_checks <- succ counters.admission_checks

let note_quiescent_return counters =
  if counters.enabled then
    counters.quiescent_returns <- succ counters.quiescent_returns

let note_work_class_zero_crossing counters =
  if counters.enabled then
    counters.work_class_zero_crossings <- succ counters.work_class_zero_crossings
