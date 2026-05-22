open! Portable

type error : immutable_data =
  | Invalid of int

module Island = struct
  let with_scheduler f =
    let scheduler = Parallel_scheduler.create ~max_domains:2 () in
    Fun.protect
      ~finally:(fun () -> Parallel_scheduler.stop scheduler)
      (fun () -> f scheduler)

  let map_result_pair (f @ portable) left right =
    with_scheduler (fun scheduler ->
        Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
            let #(left, right) =
              Parallel.fork_join2 parallel (fun _ -> f left) (fun _ -> f right)
            in
            (left, right)))

  let all_settled (f @ portable) inputs =
    let rec loop acc = function
      | [] -> List.rev acc
      | [ x ] -> List.rev (f x :: acc)
      | left :: right :: rest ->
          let left, right = map_result_pair f left right in
          loop (right :: left :: acc) rest
    in
    loop [] inputs
end

let (validate @ portable) n =
  if n mod 5 = 0 then Error (Invalid n) else Ok (n * 2)

let () =
  let results = Island.all_settled validate (List.init 20 (fun n -> n + 1)) in
  let oks, errors =
    List.fold_left
      (fun (oks, errors) -> function
        | Ok _ -> (oks + 1, errors)
        | Error _ -> (oks, errors + 1))
      (0, 0) results
  in
  if oks <> 16 || errors <> 4 then failwith "all_settled counts changed";
  Printf.printf "island all_settled=true oks=%d typed_errors=%d\n%!" oks errors
