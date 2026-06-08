open! Portable

type failure : immutable_data = { task_index : int; message : string }

let reassemble_by_task_index failures =
  let slots = Array.make (List.length failures) None in
  List.iter
    (fun failure -> slots.(failure.task_index) <- Some failure.message)
    failures;
  Array.to_list slots |> List.map Option.get

let () =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
          let #(late, early) =
            Parallel.fork_join2 parallel
              (fun _ ->
                [
                  { task_index = 7; message = "seven" };
                  { task_index = 6; message = "six" };
                  { task_index = 5; message = "five" };
                  { task_index = 4; message = "four" };
                ])
              (fun _ ->
                [
                  { task_index = 3; message = "three" };
                  { task_index = 2; message = "two" };
                  { task_index = 1; message = "one" };
                  { task_index = 0; message = "zero" };
                ])
          in
          let observed_completion_order = late @ early in
          let ordered = reassemble_by_task_index observed_completion_order in
          if
            ordered
            <> [ "zero"; "one"; "two"; "three"; "four"; "five"; "six"; "seven" ]
          then failwith "portable supervisor failures were not task-index ordered";
          Printf.printf "portable_task_index_order_positive count=%d\n%!"
            (List.length ordered)))
