open Eta

let run effect =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  Runtime.run rt effect

let run_ok label effect =
  match run effect with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "%s failed: %a\n%!" label
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
        cause;
      exit 1

let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.0)

let () =
  let conn = Fake_multiplex_connection.create () in
  let total = 12_800 in
  let concurrent = 128 in
  let iterations = total / concurrent in
  let effect =
    Multiplexer.with_connection ~max_streams:concurrent conn (fun mux ->
        Effect.for_each_par (List.init concurrent Fun.id) (fun worker ->
            let rec loop n =
              if n = 0 then Effect.unit
              else
                Multiplexer.request ~body_chunks:1 mux ~tag:((worker * iterations) + n)
                |> Effect.bind (fun _ -> loop (n - 1))
            in
            loop iterations)
        |> Effect.bind (fun _ ->
               Effect.sync (fun () -> Multiplexer.stats mux)))
  in
  Gc.compact ();
  let before = Gc.stat () in
  let started = now_us () in
  let stats = run_ok "alloc sample" effect in
  let elapsed_us = now_us () - started in
  let after = Gc.stat () in
  let minor_words = after.minor_words -. before.minor_words in
  let promoted_words = after.promoted_words -. before.promoted_words in
  let major_words = after.major_words -. before.major_words in
  Printf.printf
    "h_d1_alloc streams=%d concurrent=%d elapsed_ms=%d minor_words=%.0f promoted_words=%.0f major_words=%.0f words_per_stream=%.1f max_inflight=%d opened=%d completed=%d local_resets=%d remote_resets=%d admission_rejected=%d\n%!"
    total concurrent (elapsed_us / 1000) minor_words promoted_words major_words
    (minor_words /. float_of_int total)
    stats.Stream_state.max_inflight stats.opened stats.completed
    stats.local_resets stats.remote_resets stats.admission_rejected
