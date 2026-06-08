open Generators

(* RFC 9113 section 5.3.2: PRIORITY is deprecated. The adapter accepts the
   frame and ignores scheduling information. *)
let seed = 47_010
let trials = 120

let make_ops rng =
  random_ops rng |> List.filter (( <> ) Push_promise) |> ensure Priority

let interesting ops = count (( = ) Priority) ops > 0

let check ops =
  let model = Model.run ops in
  model.priority_seen > 0 && not model.priority_honored

let run () =
  run_trials ~name:"property_j_priority_accepted_ignored" ~seed ~trials
    ~coverage_label:"priority_sequences" ~interesting ~check ~make_ops
