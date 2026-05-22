open! Portable

type message : immutable_data = { index : int; value : string }

let completion_order = List.init 16 (fun offset -> 15 - offset)

let unordered_result =
  List.map
    (fun index -> { index; value = Printf.sprintf "task_%02d" index })
    completion_order

let () =
  let observed = List.map (fun message -> message.value) unordered_result in
  let expected = List.init 16 (fun index -> Printf.sprintf "task_%02d" index) in
  if observed = expected then failwith "negative fixture accidentally preserved input order";
  Printf.printf
    "detected_unordered_bag_contract_break first=%s expected_first=%s\n%!"
    (List.hd observed) (List.hd expected)

