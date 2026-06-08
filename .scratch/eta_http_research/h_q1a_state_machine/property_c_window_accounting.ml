open Generators

let seed = 47_003
let trials = 300

let make_ops rng =
  random_ops rng
  |> ensure_pred (fun () -> Data 1024) (function Data _ -> true | _ -> false)
  |> ensure_pred (fun () -> Window_update 1024) (function Window_update _ -> true | _ -> false)

let interesting ops = count (function Data _ -> true | _ -> false) ops >= 2

let check ops =
  let model = Model.run ops in
  model.min_window >= 0 && model.window >= 0

let run () =
  run_trials ~name:"property_c_window_never_negative" ~seed ~trials
    ~coverage_label:"multi_data_sequences" ~interesting ~check ~make_ops
