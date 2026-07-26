open Eta

let run_effect case depth (Probe_cases.Run (eff, verify)) =
  let runtime = Eta_jsoo.Runtime.create () in
  Eta_jsoo.Runtime.run runtime eff ~on_result:(fun exit_value ->
      Probe_output.finish_exit ~case ~depth verify exit_value;
      Stdlib.exit 0)

let run case depth =
  match Probe_cases.prepare case depth with
  | Error detail -> Probe_output.fail ~case ~depth ~mode:"invalid" detail
  | Ok (Probe_cases.Synchronous test) -> (
      match test () with
      | Ok () -> Probe_output.pass ~case ~depth
      | Error detail -> Probe_output.fail ~case ~depth ~mode:"wrong_result" detail)
  | Ok (Probe_cases.Effect runnable) -> run_effect case depth runnable

let () =
  match Probe_output.arguments () with
  | Error detail ->
      Probe_output.fail ~case:"arguments" ~depth:(-1) ~mode:"invalid" detail
  | Ok (case, depth) -> (
      try run case depth with exn -> Probe_output.classify_exception ~case ~depth exn)
