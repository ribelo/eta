open! Portable

type trace_context : immutable_data = {
  trace_id : string;
  parent_span_id : string;
  trace_flags : int;
}

type portable_event : immutable_data =
  | Span_start of {
      task_id : int;
      event_index : int;
      trace_id : string;
      parent_span_id : string;
      child_span_id : string;
    }
  | Attr_set of {
      task_id : int;
      event_index : int;
      key : string;
      value : string;
    }
  | Span_end of { task_id : int; event_index : int; child_span_id : string }
  | Log of {
      task_id : int;
      event_index : int;
      body : string;
      trace_id : string;
    }
  | Metric of { task_id : int; event_index : int; name : string; value : int }

let task_id = function
  | Span_start { task_id; _ }
  | Attr_set { task_id; _ }
  | Span_end { task_id; _ }
  | Log { task_id; _ }
  | Metric { task_id; _ } ->
      task_id

let event_index = function
  | Span_start { event_index; _ }
  | Attr_set { event_index; _ }
  | Span_end { event_index; _ }
  | Log { event_index; _ }
  | Metric { event_index; _ } ->
      event_index

let compare_event left right =
  match compare (task_id left) (task_id right) with
  | 0 -> compare (event_index left) (event_index right)
  | order -> order

let worker_events context task_id =
  let child_span_id = Printf.sprintf "child-%d" task_id in
  [
    Span_start
      {
        task_id;
        event_index = 0;
        trace_id = context.trace_id;
        parent_span_id = context.parent_span_id;
        child_span_id;
      };
    Attr_set
      { task_id; event_index = 1; key = "worker"; value = string_of_int task_id };
    Attr_set { task_id; event_index = 2; key = "phase"; value = "h3" };
    Log
      {
        task_id;
        event_index = 3;
        body = Printf.sprintf "worker-%d-complete" task_id;
        trace_id = context.trace_id;
      };
    Metric { task_id; event_index = 4; name = "effet.worker.events"; value = 1 };
    Span_end { task_id; event_index = 5; child_span_id };
  ]

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let run_workers context =
  with_scheduler (fun scheduler ->
    Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
      let #(left, right) =
        Parallel.fork_join2 parallel
          (fun _ -> worker_events context 0 @ worker_events context 1)
          (fun _ -> worker_events context 2 @ worker_events context 3)
      in
      left @ right))

let reassemble events = List.sort compare_event events

let metric_total events =
  List.fold_left
    (fun acc -> function Metric { value; _ } -> acc + value | _ -> acc)
    0 events

let count_attrs task_id events =
  List.fold_left
    (fun acc -> function
      | Attr_set { task_id = seen; _ } when seen = task_id -> acc + 1
      | _ -> acc)
    0 events

let rec burn i acc =
  if i <= 0 then acc
  else
    let acc = ((acc * 1_664_525) lxor (i * 1_013_904_223)) land 0x3fffffff in
    burn (i - 1) acc

let synthetic_events n =
  let context =
    { trace_id = "trace"; parent_span_id = "parent"; trace_flags = 1 }
  in
  List.init n
    (fun task_id ->
      let checksum = burn 3_000 (task_id + 11) in
      Attr_set
        {
          task_id;
          event_index = -1;
          key = "checksum";
          value = string_of_int checksum;
        }
      :: worker_events context task_id)
  |> List.flatten

let () =
  let context =
    {
      trace_id = "4bf92f3577b34da6a3ce929d0e0e4736";
      parent_span_id = "00f067aa0ba902b7";
      trace_flags = 1;
    }
  in
  let raw_events = run_workers context in
  let ordered = reassemble raw_events in
  let child_spans =
    List.fold_left
      (fun acc -> function Span_start _ -> acc + 1 | _ -> acc)
      0 ordered
  in
  if child_spans <> 4 then failwith "span hierarchy lost children";
  for task_id = 0 to 3 do
    if count_attrs task_id ordered <> 2 then failwith "worker attributes lost"
  done;
  if metric_total ordered <> 4 then failwith "metric aggregation failed";

  let generated_start = Unix.gettimeofday () in
  let heavy = synthetic_events 2_000 in
  let generated_finish = Unix.gettimeofday () in
  let reassemble_start = Unix.gettimeofday () in
  let _ = reassemble heavy in
  let reassemble_finish = Unix.gettimeofday () in
  let generate_us = (generated_finish -. generated_start) *. 1_000_000.0 in
  let reassemble_us = (reassemble_finish -. reassemble_start) *. 1_000_000.0 in
  let total_us = generate_us +. reassemble_us in
  let pct =
    if total_us = 0.0 then 0.0 else (reassemble_us /. total_us) *. 100.0
  in
  Printf.printf
    "observability_positive child_spans=%d attrs_per_child=2 metric_total=%d reassembly_us=%.0f reassembly_pct=%.2f\n%!"
    child_spans (metric_total ordered) reassemble_us pct
