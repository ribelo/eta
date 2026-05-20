open Common

let default_batch_size = 400
let max_attempts = 3

let export_batch ~collector_failures batch =
  let rec loop failures_left attempt diagnostics =
    if failures_left <= 0 then
      ( failures_left,
        {
          delivered = batch.size;
          dropped = 0;
          attempts = attempt;
          diagnostics = List.rev diagnostics;
        } )
    else if attempt >= max_attempts then
      ( failures_left - 1,
        {
          delivered = 0;
          dropped = batch.size;
          attempts = attempt;
          diagnostics =
            List.rev
              (Printf.sprintf "self_debug: dropped %d %s item(s) after retries"
                 batch.size (signal_name batch.signal)
              :: diagnostics);
        } )
    else
      loop (failures_left - 1) (attempt + 1)
        (Printf.sprintf "self_debug: retry %d for %s batch" attempt
           (signal_name batch.signal)
        :: diagnostics)
  in
  loop collector_failures 1 []

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
         chunks_of ~batch_size:default_batch_size signal count)
  |> export ~collector_failures

let export_under_slow_collector ~queue_capacity counts =
  let queued = List.fold_left (fun acc (_, count) -> acc + count) 0 counts in
  if queued <= queue_capacity then
    {
      delivered = queued;
      dropped = 0;
      attempts = 1;
      diagnostics = [ "bounded queue: accepted all items" ];
    }
  else
    {
      delivered = queue_capacity;
      dropped = queued - queue_capacity;
      attempts = 1;
      diagnostics =
        [
          Printf.sprintf
            "self_debug: bounded queue full; dropped %d item(s)"
            (queued - queue_capacity);
        ];
    }
