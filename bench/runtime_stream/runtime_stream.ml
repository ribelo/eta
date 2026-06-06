open Eta
open Eta_stream

let run_stream stream sink =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  ignore (Runtime.run rt (run stream sink) : (_, _) Exit.t)

let range n = Eta_stream.Stream.from_iterable (List.init n (fun i -> i + 1))

let map_filter_fold n =
  range n |> Eta_stream.Stream.map (fun x -> x * 2) |> Eta_stream.Stream.filter (fun x -> x mod 3 = 0)
  |> fun s -> run_stream s (Sink.fold ( + ) 0)

let map_take_fold n k =
  range n |> Eta_stream.Stream.map (fun x -> x * 2) |> Eta_stream.Stream.take k
  |> fun s -> run_stream s (Sink.fold ( + ) 0)

let merge_count ?(take = max_int) () =
  let left = range 10_000 in
  let right = range 10_000 in
  Eta_stream.Stream.merge left right |> Eta_stream.Stream.take take |> fun s -> run_stream s Sink.count

let flat_map_par n c =
  range n
  |> Eta_stream.Stream.flat_map_par ~max_concurrency:c (fun _ -> range 100)
  |> fun s -> run_stream s Sink.count

let ensure_file path size =
  let ensure_dir dir =
    if not (Sys.file_exists dir) then Unix.mkdir dir 0o755
  in
  ensure_dir "bench";
  ensure_dir "bench/fixtures";
  ensure_dir (Filename.dirname path);
  if not (Sys.file_exists path) then begin
    let oc = open_out_bin path in
    let buf = Bytes.create 4096 in
    let rng = Stdlib.Random.State.make [| 0xEFFE7 |] in
    for _ = 1 to size / 4096 do
      for i = 0 to 4095 do
        Bytes.set_uint8 buf i (Stdlib.Random.State.int rng 256)
      done;
      output_bytes oc buf
    done;
    close_out oc
  end

let from_file size chunk take =
  Eio_main.run @@ fun stdenv ->
  let file = Printf.sprintf "bench/fixtures/cache/stream-%d.bin" size in
  ensure_file file size;
  Eio.Switch.run @@ fun sw ->
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  let path = Eio.Path.(Eio.Stdenv.cwd stdenv / file) in
  let stream = Eta_stream.Stream.from_file ~chunk_size:chunk path |> Eta_stream.Stream.take take in
  ignore (Runtime.run rt (run stream Sink.count) : (_, _) Exit.t)

let workloads =
  let item name run =
    { Bench_lib.name = "eta_stream." ^ name; run; samples = None }
  in
  [
    item "range.map.filter.fold.1k" (fun () -> map_filter_fold 1_000);
    item "range.map.filter.fold.100k" (fun () -> map_filter_fold 100_000);
    item "range.map.filter.fold.1M" (fun () -> map_filter_fold 1_000_000);
    item "range.map.take.fold.1M.100" (fun () -> map_take_fold 1_000_000 100);
    item "merge.simple" (fun () -> merge_count ());
    item "merge.early_take.5" (fun () -> merge_count ~take:5 ());
    item "flat_map_par.64.1" (fun () -> flat_map_par 64 1);
    item "flat_map_par.64.4" (fun () -> flat_map_par 64 4);
    item "flat_map_par.64.16" (fun () -> flat_map_par 64 16);
    item "from_file.1MiB.4KiB" (fun () -> from_file (1024 * 1024) 4096 max_int);
    item "from_file.16MiB.64KiB" (fun () -> from_file (16 * 1024 * 1024) 65536 max_int);
    item "from_file.16MiB.1MiB" (fun () -> from_file (16 * 1024 * 1024) (1024 * 1024) max_int);
    item "from_file.take.1" (fun () -> from_file (16 * 1024 * 1024) 4096 1);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
