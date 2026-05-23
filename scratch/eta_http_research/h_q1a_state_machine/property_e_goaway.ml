open Generators

let seed = 47_005
let trials = 300

let make_ops rng = Goaway 1 :: Open :: Open :: random_ops rng

let interesting ops = count (function Goaway _ -> true | _ -> false) ops > 0

let check ops =
  let model = Model.run ops in
  model.opened_after_goaway = model.rejected_after_goaway

let run () =
  run_trials ~name:"property_e_goaway_blocks_new_streams" ~seed ~trials
    ~coverage_label:"sequences_with_goaway" ~interesting ~check ~make_ops
