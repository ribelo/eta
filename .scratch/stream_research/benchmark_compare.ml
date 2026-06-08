let measure label f =
  Gc.full_major ();
  let before = Gc.quick_stat () in
  let t0 = Unix.gettimeofday () in
  let result = f () in
  let t1 = Unix.gettimeofday () in
  let after = Gc.quick_stat () in
  let words = after.minor_words +. after.major_words -. before.minor_words -. before.major_words in
  Printf.printf "%s: %.4fs %.0f_words\n%!" label (t1 -. t0) words;
  result

let expect_ok label expected = function
  | Ok actual when actual = expected -> ()
  | Ok actual ->
      failwith (Printf.sprintf "%s: expected %d, got %d" label expected actual)
  | Error _ -> failwith (label ^ ": unexpected error")

let run_pull_full n =
  let stats = Stream_research.S_b2_pull_core.create_stats () in
  let open Stream_research.S_b2_pull_core in
  let stream =
    Stream.range 1 n
    |> Stream.map (fun x -> x * 2)
    |> Stream.filter (fun x -> x mod 3 = 0)
  in
  let result = Effect.run (object end) (run ~stats stream (Sink.fold (fun acc _ -> acc + 1) 0)) in
  Printf.printf "pull_core stats: pulls=%d chunks=%d elements=%d\n%!"
    stats.pulls stats.chunks stats.elements;
  result

let run_eio_full n =
  let stats = Stream_research.S_d_eio_chunked.create_stats () in
  let open Stream_research.S_d_eio_chunked in
  let stream =
    Stream.range 1 n
    |> Stream.map (fun x -> x * 2)
    |> Stream.filter (fun x -> x mod 3 = 0)
  in
  let result = Effect.run (object end) (run ~stats stream (Sink.fold (fun acc _ -> acc + 1) 0)) in
  Printf.printf "eio_chunked stats: fibers=%d chunks_sent=%d elements_sent=%d\n%!"
    stats.fibers stats.chunks_sent stats.elements_sent;
  result

let run_pull_take () =
  let stats = Stream_research.S_b2_pull_core.create_stats () in
  let open Stream_research.S_b2_pull_core in
  Stream_research.Services.reset ();
  let stream =
    Stream.resource "bench-pull" (Stream_research.Services.range 1 1_000_000)
    |> Stream.take 5
  in
  let result = Effect.run (object end) (run ~stats stream (Sink.fold (fun acc _ -> acc + 1) 0)) in
  Printf.printf "pull_take stats: pulls=%d chunks=%d elements=%d closes=%d\n%!"
    stats.pulls stats.chunks stats.elements
    (Stream_research.Services.close_count "bench-pull");
  result

let run_eio_take () =
  let stats = Stream_research.S_d_eio_chunked.create_stats () in
  let open Stream_research.S_d_eio_chunked in
  Stream_research.Services.reset ();
  let stream =
    Stream.resource "bench-eio" (Stream_research.Services.range 1 1_000_000)
    |> Stream.take 5
  in
  let result = Effect.run (object end) (run ~stats stream (Sink.fold (fun acc _ -> acc + 1) 0)) in
  Printf.printf "eio_take stats: fibers=%d chunks_sent=%d elements_sent=%d closes=%d\n%!"
    stats.fibers stats.chunks_sent stats.elements_sent
    (Stream_research.Services.close_count "bench-eio");
  result

let () =
  Eio_main.run @@ fun _env ->
  let n = 1_000_000 in
  let expected = n / 3 in
  measure "pull_core full" (fun () -> run_pull_full n)
  |> expect_ok "pull_core full" expected;
  measure "eio_chunked full" (fun () -> run_eio_full n)
  |> expect_ok "eio_chunked full" expected;
  measure "pull_core take5" run_pull_take |> expect_ok "pull_core take5" 5;
  measure "eio_chunked take5" run_eio_take |> expect_ok "eio_chunked take5" 5
