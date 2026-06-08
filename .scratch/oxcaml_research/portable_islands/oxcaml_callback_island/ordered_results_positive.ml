open! Portable

module Island = struct
  let with_scheduler f =
    let scheduler = Parallel_scheduler.create ~max_domains:2 () in
    Fun.protect
      ~finally:(fun () -> Parallel_scheduler.stop scheduler)
      (fun () -> f scheduler)

  let map_pair (f @ portable) left right =
    with_scheduler (fun scheduler ->
        Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
            let #(left, right) =
              Parallel.fork_join2 parallel (fun _ -> f left) (fun _ -> f right)
            in
            (left, right)))

  let map (f @ portable) inputs =
    let rec loop acc = function
      | [] -> List.rev acc
      | [ x ] -> List.rev (f x :: acc)
      | left :: right :: rest ->
          let left, right = map_pair f left right in
          loop (right :: left :: acc) rest
    in
    loop [] inputs
end

let rec burn n acc =
  if n = 0 then acc else burn (n - 1) (((acc * 33) + n) land 0xffff)

let (identity_after_work @ portable) n =
  ignore (burn ((31 - n) * 400) n);
  n

let () =
  let inputs = List.init 32 Fun.id in
  let results = Island.map identity_after_work inputs in
  if results <> inputs then failwith "portable island lost input order";
  Printf.printf "island ordered_results=true items=%d bounded=2\n%!"
    (List.length inputs)
