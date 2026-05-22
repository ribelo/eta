open! Portable

type failure : immutable_data = { task_index : int; message : string }

let reverse_completion =
  List.init 8 (fun offset ->
      let task_index = 7 - offset in
      { task_index; message = Printf.sprintf "failure_%d" task_index })

let supervisor_failures ~max_failures failures =
  List.sort (fun a b -> compare a.task_index b.task_index) failures
  |> List.filteri (fun index _ -> index < max_failures)

let () =
  let first_three = supervisor_failures ~max_failures:3 reverse_completion in
  let observed = List.map (fun failure -> failure.task_index) first_three in
  if observed <> [ 0; 1; 2 ] then
    failwith "max_failures threshold is not deterministic";
  Printf.printf "max_failures_positive threshold=3 observed=%s\n%!"
    (String.concat "," (List.map string_of_int observed))

