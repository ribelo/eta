let rec split n xs =
  if n = 0 then ([], xs)
  else
    match xs with
    | [] -> ([], [])
    | x :: rest ->
        let batch, tail = split (n - 1) rest in
        (x :: batch, tail)

[@@@alert "-do_not_spawn_domains"]
[@@@alert "-unsafe_multidomain"]

let map_bounded ~max_domains f inputs =
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
        store index (f input);
        worker ()
  in
  let domains = List.init (min max_domains count) (fun _ -> Domain.spawn worker) in
  List.iter Domain.join domains;
  Array.to_list
    (Array.map
       (function
         | Some result -> result
         | None -> failwith "cpu pool missing result")
       results)

let rec burn n acc =
  if n = 0 then acc else burn (n - 1) (((acc * 33) + n) land 0xffff)

let () =
  Eio_main.run @@ fun env ->
  ignore env;
  let inputs = List.init 32 Fun.id in
  let results =
    map_bounded ~max_domains:2
      (fun n ->
        ignore (burn ((31 - n) * 400) n);
        n)
      inputs
  in
  if results <> inputs then failwith "mainline CPU pool lost input order";
  Printf.printf "baseline ordered_results=true items=%d bounded=2\n%!"
    (List.length inputs)
