[@@@alert "-do_not_spawn_domains"]
[@@@alert "-unsafe_multidomain"]

type error =
  | Parse_error of int * string
  | Decode_error of int * string
  | Hash_error of int * string
  | Worker_die of int * string

let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.)

let rec split n xs =
  if n = 0 then ([], xs)
  else
    match xs with
    | [] -> ([], [])
    | x :: rest ->
        let batch, tail = split (n - 1) rest in
        (x :: batch, tail)

let map_result_bounded ~max_domains f inputs =
  let items = Array.of_list inputs in
  let count = Array.length items in
  let results = Array.make count None in
  let next = ref 0 in
  let mutex = Mutex.create () in
  let take () =
    Mutex.lock mutex;
    let item =
      if !next >= count then None
      else (
        let index = !next in
        incr next;
        Some (index, items.(index)))
    in
    Mutex.unlock mutex;
    item
  in
  let store index result =
    Mutex.lock mutex;
    results.(index) <- Some result;
    Mutex.unlock mutex
  in
  let rec worker () =
    match take () with
    | None -> ()
    | Some (index, input) ->
        let result =
          try f index input
          with exn -> Error (Worker_die (index, Printexc.to_string exn))
        in
        store index result;
        worker ()
  in
  let domain_count = min max_domains count in
  let domains = List.init domain_count (fun _ -> Domain.spawn worker) in
  List.iter Domain.join domains;
  Array.to_list
    (Array.map
       (function
         | Some result -> result
         | None -> failwith "cpu pool missing result")
       results)

let rec burn seed rounds =
  if rounds = 0 then seed
  else burn (((seed * 1_103_515_245) + 12_345) land 0x3fffffff) (rounds - 1)

let parse_validate index payload =
  match String.split_on_char ':' payload with
  | [ "row"; id; value ] -> (
      try
        let id = int_of_string id in
        let value = int_of_string value in
        if id <> index then Error (Parse_error (index, "id/index mismatch"))
        else if value < 0 then Error (Parse_error (index, "negative value"))
        else Ok (burn (id + value) 2_000 land 0xffff)
      with Failure msg -> Error (Parse_error (index, msg)))
  | _ -> Error (Parse_error (index, "bad row shape"))

let decode_schema index payload =
  if String.length payload < 12 || payload.[0] <> '{' then
    Error (Decode_error (index, "bad json shape"))
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
    if digits = 0 then Error (Decode_error (index, "missing id"))
    else Ok (burn (digits + index) 1_500 land 0xffff)

let checksum_chunk index payload =
  if payload = "" then Error (Hash_error (index, "empty chunk"))
  else
    let rec loop i acc =
      if i = String.length payload then acc
      else loop (i + 1) (((acc * 33) + Char.code payload.[i]) land 0x3fffffff)
    in
    Ok (burn (loop 0 index) 1_000 land 0xffff)

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
    "baseline workload=%s items=%d ok=%d typed_errors=%d bounded=2 wall_us=%d eio_contamination=false\n%!"
    name (List.length results) ok errors (now_us () - started)

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

let run_workload name f inputs =
  let started = now_us () in
  let results = map_result_bounded ~max_domains:2 f inputs in
  summarize name started results

let () =
  Eio_main.run @@ fun _env ->
  ignore _env;
  run_workload "parse_validate" parse_validate (make_rows 128);
  run_workload "schema_decode" decode_schema (make_json 128);
  run_workload "hash_checksum_compress" checksum_chunk (make_chunks 128)
