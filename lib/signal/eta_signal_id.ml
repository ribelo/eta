type signal = Signal_id of int
type scope = Scope_id of int
type var = Var_id of int
type observer = Observer_id of int

let signal id = Signal_id id
let scope id = Scope_id id
let var id = Var_id id
let observer id = Observer_id id

let signal_int (Signal_id id) = id
let scope_int (Scope_id id) = id
let var_int (Var_id id) = id
let observer_int (Observer_id id) = id

let signal_label id = "s" ^ string_of_int (signal_int id)
let dead_signal_label id = "dead_" ^ signal_label id
let scope_label id = "sc" ^ string_of_int (scope_int id)
let var_label id = "v" ^ string_of_int (var_int id)
let observer_label id = "o" ^ string_of_int (observer_int id)

let compare_observer left right =
  Int.compare (observer_int left) (observer_int right)
