let fail msg = failwith msg

let check label cond =
  if cond then Printf.printf "PASS %s\n%!" label else fail ("FAIL " ^ label)

let coverage_value label result =
  result.Generators.coverage |> List.assoc_opt label |> Option.value ~default:0

let print_result result =
  Printf.printf "PROPERTY %s seed=%d trials=%d\n%!" result.Generators.name
    result.seed result.trials;
  List.iter
    (fun (label, count) -> Printf.printf "COVERAGE %s=%d\n%!" label count)
    result.coverage;
  match result.shrunk_failure with
  | None -> Printf.printf "SHRINK none\n%!"
  | Some ops ->
      Printf.printf "SHRINK %s\n%!" (Generators.pp_ops ops)

let require_coverage result label minimum =
  check (result.Generators.name ^ " coverage " ^ label)
    (coverage_value label result >= minimum)

let run_property result coverage_label minimum =
  Generators.require_no_failure result;
  print_result result;
  require_coverage result coverage_label minimum

let () =
  run_property (Property_a_permits.run ()) "sequences_with_cancel_or_rst" 30;
  run_property (Property_b_no_body_after_rst.run ()) "rst_and_data_sequences" 30;
  run_property (Property_c_window_accounting.run ()) "multi_data_sequences" 30;
  run_property (Property_d_trailers.run ()) "sequences_with_trailers" 30;
  run_property (Property_e_goaway.run ()) "sequences_with_goaway" 30;
  run_property (Property_f_body_exhaustion.run ()) "multi_read_sequences" 30;
  run_property (Property_g_retry_classifier.run ()) "retryable_outcomes" 30;
  run_property (Property_h_pool_arithmetic.run ()) "open_release_sequences" 30;
  run_property (Property_i_server_push.run ()) "push_promise_sequences" 1;
  run_property (Property_j_priority.run ()) "priority_sequences" 1;
  Printf.printf "h_q1a_state_machine properties passed\n%!"
