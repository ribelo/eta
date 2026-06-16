let main () =
  let trace_path =
    match Sys.argv with
    | [| _; path |] -> path
    | _ ->
        Printf.eprintf "usage: trace_summary <trace-file>\n";
        exit 1
  in
  let reader = Memtrace.Trace.Reader.open_ ~filename:trace_path in
  let info = Memtrace.Trace.Reader.info reader in
  Printf.printf "sample_rate: %g\n" info.sample_rate;
  Printf.printf "word_size: %d\n" info.word_size;
  let totals = Hashtbl.create 1024 in
  let samples = Hashtbl.create 1024 in
  let entries = ref 0 in
  Memtrace.Trace.Reader.iter reader (fun _delta event ->
      match event with
      | Memtrace.Trace.Event.Alloc
          { length; nsamples; backtrace_buffer; backtrace_length; _ } ->
          incr entries;
          let locs =
            Array.sub backtrace_buffer 0 backtrace_length
            |> Array.to_list
            |> List.map (Memtrace.Trace.Reader.lookup_location_code reader)
            |> List.concat
          in
          let key =
            let is_bench_router loc =
              let s = Memtrace.Trace.Location.to_string loc in
              String.starts_with ~prefix:"Dune__exe__Bench_router" s
              || String.starts_with ~prefix:"Dune__exe.Bench_lib" s
              || String.starts_with ~prefix:"Bench_lib" s
            in
            let rec deepest_non_bench = function
              | [] -> "<unknown>"
              | [ last ] -> Memtrace.Trace.Location.to_string last
              | last :: rest ->
                  if is_bench_router last then deepest_non_bench rest
                  else Memtrace.Trace.Location.to_string last
            in
            deepest_non_bench (List.rev locs)
          in
          Hashtbl.replace totals key
            (try Hashtbl.find totals key + length with Not_found -> length);
          Hashtbl.replace samples key
            (try Hashtbl.find samples key + nsamples with Not_found -> nsamples)
      | _ -> ());
  let sorted =
    Hashtbl.to_seq totals
    |> List.of_seq
    |> List.sort (fun (_, a) (_, b) -> compare b a)
  in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  Printf.printf "trace: %s\n" trace_path;
  Printf.printf "allocation events: %d\n" !entries;
  Printf.printf "%-80s %12s %12s\n" "location" "words" "samples";
  List.iter
    (fun (key, words) ->
      let s = try Hashtbl.find samples key with Not_found -> 0 in
      Printf.printf "%-80s %12d %12d\n" key words s)
    (take 30 sorted)

let () = main ()
