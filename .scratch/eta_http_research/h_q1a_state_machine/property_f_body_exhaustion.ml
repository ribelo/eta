open Generators

let seed = 47_006
let trials = 300

let make_ops rng = Open :: End_stream :: Read_body :: Read_body :: random_ops rng

let interesting ops = count (( = ) Read_body) ops >= 2

let check ops =
  let model = Model.run ops in
  model.exhausted_count <= 1

let run () =
  run_trials ~name:"property_f_body_exhausted_once" ~seed ~trials
    ~coverage_label:"multi_read_sequences" ~interesting ~check ~make_ops
