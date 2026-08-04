type ('graph, 'snapshot, 'fault, 'census) t = {
  reset : unit -> unit;
  snapshot : unit -> 'snapshot;
  set_fault : 'fault option -> unit;
  census : unit -> 'census;
}

let create ~reset ~snapshot ~set_fault ~census =
  { reset; snapshot; set_fault; census }

let reset t = t.reset ()
let snapshot t = t.snapshot ()
let set_fault t fault = t.set_fault fault
let census t = t.census ()
