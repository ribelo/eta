open! Portable

type error : immutable_data =
  | Invalid of string

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

  let map_result_pair (f @ portable) left right =
    with_scheduler (fun scheduler ->
        Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
            let #(left, right) =
              Parallel.fork_join2 parallel (fun _ -> f left) (fun _ -> f right)
            in
            (left, right)))

  let for_each (f @ portable) inputs =
    let rec loop acc = function
      | [] -> List.rev acc
      | [ x ] -> List.rev (f x :: acc)
      | left :: right :: rest ->
          let left, right = map_pair f left right in
          loop (right :: left :: acc) rest
    in
    loop [] inputs

  let map_result (f @ portable) inputs =
    let rec loop acc = function
      | [] -> List.rev acc
      | [ x ] -> List.rev (f x :: acc)
      | left :: right :: rest ->
          let left, right = map_result_pair f left right in
          loop (right :: left :: acc) rest
    in
    loop [] inputs
end

let (parse @ portable) bytes = String.length bytes

let (validate @ portable) json =
  if String.length json >= 2 && json.[0] = '{' then Ok json
  else Error (Invalid "bad json")

let (encode @ portable) n =
  match n with
  | 1 -> "value:1"
  | 2 -> "value:2"
  | _ -> "value:n"

let () =
  let parsed = Island.for_each parse [ "abc"; "abcdef" ] in
  let validated = Island.map_result validate [ "{}"; "bad" ] in
  let encoded = Island.for_each encode [ 1; 2 ] in
  match (parsed, validated, encoded) with
  | [ 3; 6 ], [ Ok "{}"; Error (Invalid "bad json") ], [ "value:1"; "value:2" ]
    ->
      Printf.printf "ergonomics examples=true annotations=3 ppx_required=false\n%!"
  | _ -> failwith "ergonomics examples changed"
