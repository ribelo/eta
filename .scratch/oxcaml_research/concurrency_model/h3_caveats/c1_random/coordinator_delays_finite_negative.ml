open! Portable

type worker_result : immutable_data =
  | Ran of int
  | Missing_delay of int

type delay_batch : immutable_data = { delays_ms : int list }

let delay_for_step batch step =
  match List.nth_opt batch.delays_ms step with
  | Some delay -> Ran delay
  | None -> Missing_delay step

let () =
  let batch = { delays_ms = [ 100 ] } in
  match delay_for_step batch 1 with
  | Missing_delay 1 ->
      Printf.printf
        "coordinator_delays_finite_negative missing_step=true\n%!"
  | _ -> failwith "expected missing materialized delay"
