open! Portable

type error : immutable_data =
  | Parse_error of int * string
  | Decode_error of int * string
  | Hash_error of int * string

let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.)

let log label started =
  Printf.printf "diag %s_us=%d\n%!" label (now_us () - started)

let rec burn seed rounds =
  if rounds = 0 then seed
  else burn (((seed * 1_103_515_245) + 12_345) land 0x3fffffff) (rounds - 1)

let (parse_validate @ portable) payload =
  match String.split_on_char ':' payload with
  | [ "row"; id; value ] -> (
      try
        let id = int_of_string id in
        let value = int_of_string value in
        if value < 0 then Error (Parse_error (id, "negative value"))
        else Ok (burn (id + value) 2_000 land 0xffff)
      with Failure msg -> Error (Parse_error (0, msg)))
  | _ -> Error (Parse_error (0, "bad row shape"))

let (decode_schema @ portable) payload =
  if String.length payload < 12 || payload.[0] <> '{' then
    Error (Decode_error (0, "bad json shape"))
  else
    let digits =
      let rec loop i acc =
        if i >= String.length payload then acc
        else
          match payload.[i] with
          | '0' .. '9' as c -> loop (i + 1) ((acc * 10) + Char.code c - 48)
          | _ -> loop (i + 1) acc
      in
      loop 0 0
    in
    if digits = 0 then Error (Decode_error (0, "missing id"))
    else Ok (burn digits 1_500 land 0xffff)

let (checksum_chunk @ portable) payload =
  if String.length payload = 0 then Error (Hash_error (0, "empty chunk"))
  else
    let rec loop i acc =
      if i = String.length payload then acc
      else loop (i + 1) (((acc * 33) + Char.code payload.[i]) land 0x3fffffff)
    in
    Ok (burn (loop 0 0) 1_000 land 0xffff)

let rec map_result_with_parallel (f @ portable) parallel = function
  | [] -> []
  | [ x ] -> [ f x ]
  | left :: right :: rest ->
      let #(left, right) =
        Parallel.fork_join2 parallel (fun _ -> f left) (fun _ -> f right)
      in
      left :: right :: map_result_with_parallel f parallel rest

let summarize name results =
  let ok, errors =
    List.fold_left
      (fun (ok, errors) -> function
        | Ok _ -> (ok + 1, errors)
        | Error _ -> (ok, errors + 1))
      (0, 0) results
  in
  Printf.printf "diag workload=%s ok=%d errors=%d\n%!" name ok errors

let make_rows n =
  List.init n (fun i ->
      if i = n - 1 then Printf.sprintf "row:%d:-1" i
      else Printf.sprintf "row:%d:%d" i ((i * 17) + 3))

let make_json n =
  List.init n (fun i ->
      if i = n - 1 then "{}"
      else Printf.sprintf "{\"id\":%d,\"active\":true}" (i + 1))

let make_chunks n =
  List.init n (fun i ->
      if i = n - 1 then "" else String.make 64 (Char.chr (65 + (i mod 26))))

let run_new_scheduler name (f @ portable) inputs =
  let total = now_us () in
  let create_started = now_us () in
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  log (name ^ ".create") create_started;
  let run_started = now_us () in
  let results =
    Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        map_result_with_parallel f parallel inputs)
  in
  log (name ^ ".parallel") run_started;
  let stop_started = now_us () in
  Parallel_scheduler.stop scheduler;
  log (name ^ ".stop") stop_started;
  summarize name results;
  log (name ^ ".total") total

let run_reused_scheduler scheduler name (f @ portable) inputs =
  let total = now_us () in
  let run_started = now_us () in
  let results =
    Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        map_result_with_parallel f parallel inputs)
  in
  log (name ^ ".parallel_reused") run_started;
  summarize name results;
  log (name ^ ".total_reused") total

let () =
  Printf.printf "diag mode=new_scheduler_per_workload\n%!";
  run_new_scheduler "parse" parse_validate (make_rows 128);
  run_new_scheduler "decode" decode_schema (make_json 128);
  run_new_scheduler "hash" checksum_chunk (make_chunks 128);
  Printf.printf "diag mode=reused_scheduler\n%!";
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  run_reused_scheduler scheduler "parse" parse_validate (make_rows 128);
  run_reused_scheduler scheduler "decode" decode_schema (make_json 128);
  run_reused_scheduler scheduler "hash" checksum_chunk (make_chunks 128);
  let stop_started = now_us () in
  Parallel_scheduler.stop scheduler;
  log "reused.stop" stop_started
