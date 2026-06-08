open! Portable

type error : immutable_data =
  | Parse_error of int * string
  | Decode_error of int * string
  | Hash_error of int * string

module Island = struct
  let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.)

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

  let rec map_result_with_parallel (f @ portable) parallel = function
    | [] -> []
    | [ x ] -> [ f x ]
    | left :: right :: rest ->
        let #(left, right) =
          Parallel.fork_join2 parallel (fun _ -> f left) (fun _ -> f right)
        in
        left :: right :: map_result_with_parallel f parallel rest

  let map_result (f @ portable) inputs =
    with_scheduler (fun scheduler ->
        Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
            map_result_with_parallel f parallel inputs))

  let map_result_with_scheduler scheduler (f @ portable) inputs =
    Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        map_result_with_parallel f parallel inputs)
end

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

let summarize name started results =
  let ok, errors =
    List.fold_left
      (fun (ok, errors) -> function
        | Ok _ -> (ok + 1, errors)
        | Error _ -> (ok, errors + 1))
      (0, 0) results
  in
  if ok = 0 || errors = 0 then failwith (name ^ " did not exercise typed errors");
  Printf.printf
    "island workload=%s items=%d ok=%d typed_errors=%d bounded=2 wall_us=%d\n%!"
    name (List.length results) ok errors (Island.now_us () - started)

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

let run_workload scheduler name (f @ portable) inputs =
  let started = Island.now_us () in
  summarize name started (Island.map_result_with_scheduler scheduler f inputs)

let () =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () ->
      run_workload scheduler "parse_validate" parse_validate (make_rows 128);
      run_workload scheduler "schema_decode" decode_schema (make_json 128);
      run_workload scheduler "hash_checksum_compress" checksum_chunk
        (make_chunks 128))
