type op =
  | Open
  | Headers
  | Data of int
  | End_stream
  | Rst_stream
  | Cancel
  | Release
  | Window_update of int
  | Goaway of int
  | Push_promise
  | Priority
  | Trailer
  | Read_body

type result = {
  name : string;
  seed : int;
  trials : int;
  coverage : (string * int) list;
  shrunk_failure : op list option;
}

let string_of_op = function
  | Open -> "Open"
  | Headers -> "Headers"
  | Data bytes -> Printf.sprintf "Data(%d)" bytes
  | End_stream -> "End_stream"
  | Rst_stream -> "Rst_stream"
  | Cancel -> "Cancel"
  | Release -> "Release"
  | Window_update bytes -> Printf.sprintf "Window_update(%d)" bytes
  | Goaway last -> Printf.sprintf "Goaway(%d)" last
  | Push_promise -> "Push_promise"
  | Priority -> "Priority"
  | Trailer -> "Trailer"
  | Read_body -> "Read_body"

let pp_ops ops = String.concat "; " (List.map string_of_op ops)

let random_op rng =
  match Random.State.int rng 13 with
  | 0 -> Open
  | 1 -> Headers
  | 2 -> Data ((Random.State.int rng 8 + 1) * 1024)
  | 3 -> End_stream
  | 4 -> Rst_stream
  | 5 -> Cancel
  | 6 -> Release
  | 7 -> Window_update ((Random.State.int rng 8 + 1) * 1024)
  | 8 -> Goaway (1 + (2 * Random.State.int rng 12))
  | 9 -> Push_promise
  | 10 -> Priority
  | 11 -> Trailer
  | _ -> Read_body

let random_ops rng =
  let len = 8 + Random.State.int rng 24 in
  List.init len (fun _ -> random_op rng)

let ensure op ops = if List.exists (( = ) op) ops then ops else op :: ops

let ensure_pred make pred ops =
  if List.exists pred ops then ops else make () :: ops

let count pred ops = List.fold_left (fun acc op -> if pred op then acc + 1 else acc) 0 ops

let shrink failing ops =
  let rec prefixes acc current rest =
    match rest with
    | [] -> List.rev (current :: acc)
    | x :: xs -> prefixes (current :: acc) (current @ [ x ]) xs
  in
  prefixes [] [] ops
  |> List.filter (fun candidate -> candidate <> [])
  |> List.find_opt failing
  |> Option.value ~default:ops

let run_trials ~name ~seed ~trials ~coverage_label ~interesting ~check ~make_ops =
  let rng = Random.State.make [| seed |] in
  let coverage = ref 0 in
  let failure = ref None in
  for _ = 1 to trials do
    if Option.is_none !failure then (
      let ops = make_ops rng in
      if interesting ops then incr coverage;
      if not (check ops) then failure := Some (shrink (fun ops -> not (check ops)) ops))
  done;
  {
    name;
    seed;
    trials;
    coverage = [ (coverage_label, !coverage) ];
    shrunk_failure = !failure;
  }

let require_no_failure result =
  match result.shrunk_failure with
  | None -> ()
  | Some ops -> failwith (result.name ^ " shrunk failure: " ^ pp_ops ops)
