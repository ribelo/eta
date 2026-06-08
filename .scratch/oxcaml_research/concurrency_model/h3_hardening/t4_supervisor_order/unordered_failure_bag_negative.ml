open! Portable

type failure : immutable_data = { task_index : int; message : string }

let unordered_bag =
  List.init 8 (fun offset ->
      let task_index = 7 - offset in
      { task_index; message = Printf.sprintf "failure_%d" task_index })

let () =
  let observed = List.map (fun failure -> failure.task_index) unordered_bag in
  if observed = List.init 8 Fun.id then
    failwith "negative fixture accidentally preserved task-index order";
  Printf.printf
    "detected_unordered_failure_bag observed=%s required=0,1,2,3,4,5,6,7\n%!"
    (String.concat "," (List.map string_of_int observed))

