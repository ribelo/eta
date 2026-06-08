open! Portable

type task : immutable_data = { id : int; loops : int }

let round_robin_loads domains tasks =
  let loads = Array.make domains 0 in
  List.iteri
    (fun index task ->
      let worker = index mod domains in
      loads.(worker) <- loads.(worker) + task.loops)
    tasks;
  Array.to_list loads

let () =
  let tasks =
    [
      { id = 0; loops = 800 };
      { id = 1; loops = 10 };
      { id = 2; loops = 800 };
      { id = 3; loops = 10 };
      { id = 4; loops = 800 };
      { id = 5; loops = 10 };
    ]
  in
  let loads = round_robin_loads 2 tasks in
  match loads with
  | [ left; right ] when left > right * 20 ->
      Printf.printf
        "detected_round_robin_skew_imbalance left=%d right=%d ratio=%.1f\n%!"
        left right (float_of_int left /. float_of_int right)
  | _ -> failwith "negative fixture did not expose round-robin skew"

