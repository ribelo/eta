open! Portable

type message : immutable_data = { index : int; value : string }
type slot : immutable_data = Missing | Filled of string

let completion_order = List.init 16 (fun offset -> 15 - offset)

let collect_completion_messages () =
  List.map (fun index -> { index; value = Printf.sprintf "task_%02d" index })
    completion_order

let reassemble task_count messages =
  let slots = Array.init task_count (fun _ -> Atomic.make Missing) in
  List.iter
    (fun message -> Atomic.set slots.(message.index) (Filled message.value))
    messages;
  Array.to_list slots
  |> List.mapi (fun index slot ->
         match Atomic.get slot with
         | Filled value -> value
         | Missing -> failwith (Printf.sprintf "missing result %d" index))

let () =
  let messages = collect_completion_messages () in
  let start = Unix.gettimeofday () in
  let ordered = reassemble 16 messages in
  let elapsed_us = int_of_float ((Unix.gettimeofday () -. start) *. 1_000_000.0) in
  let expected = List.init 16 (fun index -> Printf.sprintf "task_%02d" index) in
  if ordered <> expected then failwith "input order was not restored";
  Printf.printf
    "indexed_all_positive completion_order=reverse input_order_restored=true reassembly_us=%d\n%!"
    elapsed_us

