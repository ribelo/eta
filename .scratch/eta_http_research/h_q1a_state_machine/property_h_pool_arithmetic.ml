open Generators

let seed = 47_008
let trials = 300

let make_ops rng = random_ops rng |> ensure Open |> ensure Release

let interesting ops = count (( = ) Open) ops > 0 && count (( = ) Release) ops > 0

let check ops =
  let model = Model.run ops in
  Model.pool_consistent model

let run () =
  run_trials ~name:"property_h_pool_arithmetic" ~seed ~trials
    ~coverage_label:"open_release_sequences" ~interesting ~check ~make_ops
