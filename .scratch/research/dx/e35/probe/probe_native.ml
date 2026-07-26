open Eta

let run_effect ~case ~depth (Probe_cases.Run (eff, verify)) =
  Eio_main.run @@ fun environment ->
  Eio.Switch.run @@ fun switch ->
  let runtime =
    Eta_eio.Runtime.create ~sw:switch ~clock:(Eio.Stdenv.clock environment) ()
  in
  Probe_output.finish_exit ~case ~depth verify (Runtime.run runtime eff)

let run case depth =
  match Probe_cases.prepare case depth with
  | Error detail -> Probe_output.fail ~case ~depth ~mode:"invalid" detail
  | Ok (Probe_cases.Synchronous test) -> (
      match test () with
      | Ok () -> Probe_output.pass ~case ~depth
      | Error detail -> Probe_output.fail ~case ~depth ~mode:"wrong_result" detail)
  | Ok (Probe_cases.Effect runnable) -> run_effect ~case ~depth runnable

let () =
  match Probe_output.arguments () with
  | Error detail ->
      Probe_output.fail ~case:"arguments" ~depth:(-1) ~mode:"invalid" detail;
      exit 64
  | Ok (case, depth) -> (
      try run case depth with exn -> Probe_output.classify_exception ~case ~depth exn)
