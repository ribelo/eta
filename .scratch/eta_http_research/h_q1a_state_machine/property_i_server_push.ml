open Generators

(* RFC 9113 section 8.4: with SETTINGS_ENABLE_PUSH=0, PUSH_PROMISE is a
   connection error. *)
let seed = 47_009
let trials = 120

let make_ops rng = random_ops rng |> ensure Push_promise
let interesting ops = count (( = ) Push_promise) ops > 0

let check ops =
  let model = Model.run ops in
  model.push_rejected > 0 && model.connection_error

let run () =
  run_trials ~name:"property_i_server_push_rejected" ~seed ~trials
    ~coverage_label:"push_promise_sequences" ~interesting ~check ~make_ops
