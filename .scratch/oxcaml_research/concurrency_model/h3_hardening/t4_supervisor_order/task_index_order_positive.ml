open! Portable

type failure : immutable_data = { task_index : int; message : string }

let reverse_completion =
  List.init 8 (fun offset ->
      let task_index = 7 - offset in
      { task_index; message = Printf.sprintf "failure_%d" task_index })

let supervisor_failures failures =
  List.sort (fun a b -> compare a.task_index b.task_index) failures

let () =
  let ordered = supervisor_failures reverse_completion in
  let observed = List.map (fun failure -> failure.task_index) ordered in
  if observed <> List.init 8 Fun.id then
    failwith "supervisor failures are not in task-index order";
  Printf.printf
    "task_index_order_positive completion=reverse supervisor_order=%s\n%!"
    (String.concat "," (List.map string_of_int observed))

