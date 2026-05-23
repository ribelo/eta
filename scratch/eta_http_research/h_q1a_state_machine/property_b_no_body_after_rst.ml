open Generators

let seed = 47_002
let trials = 300

let make_ops rng =
  random_ops rng |> ensure Open |> ensure Rst_stream
  |> ensure_pred (fun () -> Data 1024) (function Data _ -> true | _ -> false)

let interesting ops =
  count (( = ) Rst_stream) ops > 0 && count (function Data _ -> true | _ -> false) ops > 0

let check ops =
  let model = Model.run ops in
  model.delivered_after_rst = 0

let run () =
  run_trials ~name:"property_b_no_body_after_rst" ~seed ~trials
    ~coverage_label:"rst_and_data_sequences" ~interesting ~check ~make_ops
