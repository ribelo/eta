open Generators

let seed = 47_001
let trials = 300

let interesting ops =
  count (function Cancel | Rst_stream -> true | _ -> false) ops > 0

let make_ops rng = random_ops rng |> ensure Open |> ensure Cancel

let check ops =
  let model = Model.run ops in
  let stats = Model.finalize model in
  stats.Stream_state.active = 0 && stats.cancelled = 0 && stats.live = 0

let run () =
  run_trials ~name:"property_a_permits_return_to_baseline" ~seed ~trials
    ~coverage_label:"sequences_with_cancel_or_rst" ~interesting ~check ~make_ops
