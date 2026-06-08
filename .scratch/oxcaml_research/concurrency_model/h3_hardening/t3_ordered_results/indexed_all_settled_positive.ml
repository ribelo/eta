open! Portable

type cause : immutable_data = { code : string }
type outcome : immutable_data = Ok of string | Error of cause
type message : immutable_data = { index : int; outcome : outcome }
type slot : immutable_data = Missing | Filled of outcome

let completion_order = List.init 16 (fun offset -> 15 - offset)

let outcome index =
  if index mod 5 = 0
  then Error { code = Printf.sprintf "err_%02d" index }
  else Ok (Printf.sprintf "ok_%02d" index)

let messages =
  List.map (fun index -> { index; outcome = outcome index }) completion_order

let reassemble task_count messages =
  let slots = Array.init task_count (fun _ -> Atomic.make Missing) in
  List.iter
    (fun message -> Atomic.set slots.(message.index) (Filled message.outcome))
    messages;
  Array.to_list slots
  |> List.mapi (fun index slot ->
         match Atomic.get slot with
         | Filled outcome -> outcome
         | Missing -> failwith (Printf.sprintf "missing settled result %d" index))

let () =
  let start = Unix.gettimeofday () in
  let ordered = reassemble 16 messages in
  let elapsed_us = int_of_float ((Unix.gettimeofday () -. start) *. 1_000_000.0) in
  let expected = List.init 16 outcome in
  if ordered <> expected then failwith "all_settled order was not restored";
  let errors =
    List.fold_left
      (fun acc -> function Error _ -> acc + 1 | Ok _ -> acc)
      0 ordered
  in
  Printf.printf
    "indexed_all_settled_positive errors=%d input_order_restored=true reassembly_us=%d\n%!"
    errors elapsed_us

