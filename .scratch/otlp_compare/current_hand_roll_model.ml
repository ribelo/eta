open Common

let batch_size = function
  | Trace -> 32
  | Log -> 64
  | Metric -> 128

let export_batch ~collector_failures batch =
  if collector_failures > 0 then
    ( collector_failures - 1,
      {
        delivered = 0;
        dropped = batch.size;
        attempts = 1;
        diagnostics =
          [
            Printf.sprintf "on_error: dropped %d %s item(s)" batch.size
              (signal_name batch.signal);
          ];
      } )
  else
    ( collector_failures,
      { delivered = batch.size; dropped = 0; attempts = 1; diagnostics = [] } )

let export ~collector_failures batches =
  let _, result =
    List.fold_left
      (fun (failures_left, acc) batch ->
        let failures_left, result = export_batch ~collector_failures:failures_left batch in
        (failures_left, add_result acc result))
      (collector_failures, empty_result)
      batches
  in
  result

let export_signals ~collector_failures counts =
  counts
  |> List.concat_map (fun (signal, count) ->
         chunks_of ~batch_size:(batch_size signal) signal count)
  |> export ~collector_failures

let export_under_slow_collector ~queue_capacity:_ counts =
  let result = export_signals ~collector_failures:0 counts in
  {
    result with
    diagnostics =
      result.diagnostics
      @ [
          "slow collector: exporter loop blocks; no retry/backoff/drop telemetry \
           beyond user on_error";
        ];
  }
