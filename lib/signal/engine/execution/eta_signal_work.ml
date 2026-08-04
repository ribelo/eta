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

type class_ =
  | Sources
  | Scheduler
  | Observer_delivery
  | Timer_reconciliation
  | Cleanup

type t = {
  counters : counters;
  mutable total : int;
  counts : int array;
}

let class_index = function
  | Sources -> 0
  | Scheduler -> 1
  | Observer_delivery -> 2
  | Timer_reconciliation -> 3
  | Cleanup -> 4

let create counters = { counters; total = 0; counts = Array.make 5 0 }
let total work = work.total
let quiescent work = work.total = 0
let count work class_ = work.counts.(class_index class_)

let admit work class_ =
  note_admission_check work.counters;
  let index = class_index class_ in
  if work.counts.(index) = 0 then note_work_class_zero_crossing work.counters;
  work.counts.(index) <- work.counts.(index) + 1;
  work.total <- work.total + 1

let release work class_ =
  let index = class_index class_ in
  if work.counts.(index) = 0 then
    invalid_arg "Eta_signal_work.release: empty work class";
  work.counts.(index) <- work.counts.(index) - 1;
  work.total <- work.total - 1;
  if work.counts.(index) = 0 then note_work_class_zero_crossing work.counters

let note_quiescent work =
  if quiescent work then note_quiescent_return work.counters

let check_quiescent work =
  note_admission_check work.counters;
  if quiescent work then (
    note_quiescent_return work.counters;
    true)
  else false
