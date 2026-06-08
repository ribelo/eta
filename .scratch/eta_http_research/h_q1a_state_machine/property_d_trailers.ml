open Generators

let seed = 47_004
let trials = 300

let make_ops rng = random_ops rng |> ensure Trailer |> ensure End_stream

let interesting ops = count (( = ) Trailer) ops > 0

let check ops =
  let model = Model.run ops in
  model.trailers_delivered = 0 || model.body_ended

let run () =
  run_trials ~name:"property_d_trailers_after_end_stream" ~seed ~trials
    ~coverage_label:"sequences_with_trailers" ~interesting ~check ~make_ops
