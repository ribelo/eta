open Eta
open Eta_stream

let check_ok testable label expected = function
  | Exit.Ok actual -> Alcotest.check testable label expected actual
  | Exit.Error cause ->
      Alcotest.failf "%s: unexpected error %a" label
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause

let check_ok_unit label = function
  | Exit.Ok () -> ()
  | Exit.Error cause ->
      Alcotest.failf "%s: unexpected error %a" label
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause

let run_ok rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "unexpected error %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause

let with_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()
  in
  f env rt

let fd_count () =
  try Array.length (Sys.readdir "/proc/self/fd") with Sys_error _ -> -1

let with_file env name contents f =
  let path = Eio.Path.(Eio.Stdenv.cwd env / name) in
  Eio.Path.save ~create:(`Or_truncate 0o600) path contents;
  Fun.protect
    ~finally:(fun () -> try Eio.Path.unlink path with _ -> ())
    (fun () -> f path)

let strings_of_bytes chunks = List.map Bytes.to_string chunks

let test_basic_abc () =
  with_runtime @@ fun _env rt ->
  Stream.from_iterable [ 1; 2; 3; 4; 5; 6 ]
  |> Stream.map (( * ) 2)
  |> Stream.take 5
  |> fun stream -> run stream (Sink.fold ( + ) 0)
  |> Runtime.run rt
  |> check_ok Alcotest.int "sum" 30

let test_from_file_chunks () =
  with_runtime @@ fun env rt ->
  with_file env "stream-chunks.tmp" "abcdefg" @@ fun path ->
  match
    Stream.from_file ~chunk_size:3 path |> run_collect |> Runtime.run rt
  with
  | Exit.Ok chunks ->
      Alcotest.(check (list string))
        "chunks" [ "abc"; "def"; "g" ] (strings_of_bytes chunks)
  | Exit.Error cause ->
      Alcotest.failf "chunked from_file failed: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause

let test_take_then_file_close () =
  with_runtime @@ fun env rt ->
  let large = String.make (1024 * 1024) 'x' in
  with_file env "stream-take-close.tmp" large @@ fun path ->
  let before = fd_count () in
  let result =
    Stream.from_file ~chunk_size:4096 path
    |> Stream.take 1
    |> run_collect
    |> Runtime.run rt
  in
  (match result with
  | Exit.Ok [ chunk ] ->
      Alcotest.(check int) "one bounded chunk" 4096 (Bytes.length chunk)
  | Exit.Ok chunks ->
      Alcotest.failf "expected one chunk, got %d" (List.length chunks)
  | Exit.Error cause ->
      Alcotest.failf "take from_file failed: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause);
  let after = fd_count () in
  if before >= 0 && after > before then
    Alcotest.failf "fd count grew after from_file early take: before=%d after=%d"
      before after

let test_from_file_invalid_chunk_size () =
  Eio_main.run @@ fun env ->
  let path = Eio.Path.(Eio.Stdenv.cwd env / "unused-stream-file.tmp") in
  try
    ignore (Stream.from_file ~chunk_size:0 path);
    Alcotest.fail "from_file accepted chunk_size=0"
  with Invalid_argument _ -> ()

let test_from_file_missing_path_fails_typed () =
  with_runtime @@ fun env rt ->
  let path = Eio.Path.(Eio.Stdenv.cwd env / "missing-stream-file.tmp") in
  (try Eio.Path.unlink path with _ -> ());
  match Stream.from_file path |> run_drain |> Runtime.run rt with
  | Exit.Ok () -> Alcotest.fail "missing file unexpectedly succeeded"
  | Exit.Error
      (Cause.Fail
        (`File_error { Stream.kind = `Not_found; operation = `Open; _ })) ->
      ()
  | Exit.Error cause ->
      Alcotest.failf "missing file produced unexpected cause: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause

let test_from_file_error_is_recoverable () =
  with_runtime @@ fun env rt ->
  let path = Eio.Path.(Eio.Stdenv.cwd env / "missing-stream-file-recover.tmp") in
  (try Eio.Path.unlink path with _ -> ());
  let eff =
    Stream.from_file path |> run_drain
    |> Effect.catch (function
         | `File_error { Stream.kind = `Not_found; _ } -> Effect.unit
         | error -> Effect.fail error)
  in
  Runtime.run rt eff |> check_ok_unit "recover missing file"

let test_from_file_map_error () =
  with_runtime @@ fun env rt ->
  let path = Eio.Path.(Eio.Stdenv.cwd env / "missing-stream-file-map.tmp") in
  (try Eio.Path.unlink path with _ -> ());
  match
    Stream.from_file_map_error ~on_error:(fun error -> `Storage error) path
    |> run_drain |> Runtime.run rt
  with
  | Exit.Error
      (Cause.Fail (`Storage { Stream.kind = `Not_found; operation = `Open; _ }))
    ->
      ()
  | Exit.Ok () -> Alcotest.fail "missing file unexpectedly succeeded"
  | Exit.Error cause ->
      Alcotest.failf "mapped missing file produced unexpected cause: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause

let test_from_file_take_zero_is_lazy () =
  with_runtime @@ fun env rt ->
  let path = Eio.Path.(Eio.Stdenv.cwd env / "missing-stream-file-take-zero.tmp") in
  (try Eio.Path.unlink path with _ -> ());
  Stream.from_file path |> Stream.take 0 |> run_drain |> Runtime.run rt
  |> check_ok_unit "take zero does not open file"

let test_from_file_downstream_failure_closes () =
  with_runtime @@ fun env rt ->
  let large = String.make (1024 * 1024) 'x' in
  with_file env "stream-downstream-failure.tmp" large (fun path ->
      let before = fd_count () in
      let eff =
        Stream.from_file ~chunk_size:4096 path
        |> Stream.map_effect (fun _ -> Effect.fail `Stop)
        |> run_drain
        |> Effect.timeout (Duration.ms 1_000)
      in
      (match Runtime.run rt eff with
      | Exit.Error (Cause.Fail `Stop) -> ()
      | Exit.Ok () -> Alcotest.fail "downstream failure unexpectedly succeeded"
      | Exit.Error cause ->
          Alcotest.failf "unexpected downstream failure cause: %a"
            (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
            cause);
      let after = fd_count () in
      if before >= 0 && after > before then
        Alcotest.failf
          "fd count grew after from_file downstream failure: before=%d after=%d"
          before after)

let delayed_counted_source produced =
  Stream.from_iterable (List.init 1_000 (fun i -> i))
  |> Stream.map_effect (fun value ->
         Effect.sync "stream.produced" (fun () -> incr produced)
         |> Effect.bind (fun () ->
                Effect.delay (Duration.ms 5) (Effect.pure value)))

let test_merge_cancellation () =
  with_runtime @@ fun _env rt ->
  let left_count = ref 0 in
  let right_count = ref 0 in
  let stream =
    Stream.merge (delayed_counted_source left_count)
      (delayed_counted_source right_count)
    |> Stream.take 1
  in
  Runtime.run rt (run_drain stream) |> check_ok_unit "merge drain";
  Alcotest.(check bool) "left cancelled before full production" true
    (!left_count < 1_000);
  Alcotest.(check bool) "right cancelled before full production" true
    (!right_count < 1_000)

let test_flat_map_par_concurrency () =
  with_runtime @@ fun _env rt ->
  let input = Stream.from_iterable (List.init 100 (fun i -> i)) in
  let stream =
    Stream.flat_map_par ~max_concurrency:10
      (fun value ->
        Stream.from_effect
          (Effect.delay (Duration.ms 50) (Effect.pure value)))
      input
  in
  let started = Unix.gettimeofday () in
  let result = Runtime.run rt (run_collect stream) in
  let elapsed = Unix.gettimeofday () -. started in
  match result with
  | Exit.Ok values ->
      Alcotest.(check int) "all values" 100 (List.length values);
      Alcotest.(check bool) "runs bounded-parallel, not sequential" true
        (elapsed < 2.0)
  | Exit.Error cause ->
      Alcotest.failf "flat_map_par failed: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause

let test_bounded_queue_no_deadlock () =
  with_runtime @@ fun _env rt ->
  let left = delayed_counted_source (ref 0) in
  let right = delayed_counted_source (ref 0) in
  let eff =
    Stream.merge left right |> Stream.take 1 |> run_drain
    |> Effect.timeout (Duration.ms 1_000)
  in
  Runtime.run rt eff |> check_ok_unit "bounded queue completes"

class type db = object
  method get : int
end

let row_pipeline clock db () =
  let clock_stream =
    Stream.from_effect
      (Effect.sync "clock" (fun () ->
           clock#sleep (Duration.ms 0);
           1))
  in
  let db_stream = Stream.from_effect (Effect.sync "db" (fun () -> db#get)) in
  Stream.merge clock_stream db_stream
  |> Stream.flat_map_par ~max_concurrency:2 (fun value ->
         Stream.from_effect
           (if value < 0 then Effect.fail `Negative else Effect.pure value))
  |> run_collect

module type ROW_SIG = sig
  val row_pipeline :
    Capabilities.clock -> db -> unit -> (int list, [> `Negative ]) Effect.t
end

module _ : ROW_SIG = struct
  let row_pipeline = row_pipeline
end

let test_row_pipeline_runtime () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let db =
    object
      method get = 2
    end
  in
  let clock = Capabilities.clock_of_eio (Eio.Stdenv.clock env) in
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()
  in
  match Runtime.run rt (row_pipeline clock db ()) with
  | Exit.Ok values ->
      Alcotest.(check (list int)) "row values" [ 1; 2 ] (List.sort compare values)
  | Exit.Error cause ->
      Alcotest.failf "row pipeline failed: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause

let test_grouped_batches () =
  with_runtime @@ fun _env rt ->
  let stream = Stream.from_iterable [ 1; 2; 3; 4; 5 ] |> Stream.grouped 2 in
  Alcotest.(check (list (list int)))
    "batches" [ [ 1; 2 ]; [ 3; 4 ]; [ 5 ] ]
    (run_ok rt (run_collect stream))

let test_mailbox_stream_close_and_drop () =
  with_runtime @@ fun _env rt ->
  let mailbox = Mailbox.create ~capacity:2 () in
  (match Mailbox.offer mailbox 1 with
  | Enqueued -> ()
  | Dropped | Closed -> Alcotest.fail "expected first offer to enqueue");
  (match Mailbox.offer mailbox 2 with
  | Enqueued -> ()
  | Dropped | Closed -> Alcotest.fail "expected second offer to enqueue");
  (match Mailbox.offer mailbox 3 with
  | Dropped -> ()
  | Enqueued | Closed -> Alcotest.fail "expected full mailbox to drop");
  Alcotest.(check int) "dropped" 1 (Mailbox.dropped mailbox);
  Mailbox.close mailbox;
  Alcotest.(check (list int))
    "drain queued values" [ 1; 2 ]
    (run_ok rt (run_collect (Mailbox.to_stream mailbox)))

let test_mailbox_batch_stream_emits_partial () =
  with_runtime @@ fun _env rt ->
  let mailbox = Mailbox.create ~capacity:8 () in
  List.iter
    (fun value ->
      match Mailbox.offer mailbox value with
      | Enqueued -> ()
      | Dropped | Closed -> Alcotest.fail "expected offer to enqueue")
    [ 1; 2; 3 ];
  Mailbox.close mailbox;
  Alcotest.(check (list (list int)))
    "partial batches" [ [ 1; 2 ]; [ 3 ] ]
    (run_ok rt (run_collect (Mailbox.to_batch_stream ~max:2 mailbox)))

let test_drain_counter_await_zero () =
  with_runtime @@ fun _env rt ->
  let counter = Drain_counter.create () in
  Drain_counter.incr_by counter 2;
  let release =
    Effect.delay (Duration.ms 1)
      (Effect.sync "drain_counter.release" (fun () ->
           Drain_counter.decr_by counter 2))
  in
  let wait = Drain_counter.await_zero counter in
  Runtime.run rt
    (Effect.all [ release; wait ]
    |> Effect.map (fun _ -> ())
    |> Effect.timeout (Duration.ms 1_000))
  |> check_ok_unit "drain counter reaches zero";
  Alcotest.(check int) "counter value" 0 (Drain_counter.value counter)

let suite =
  ( "Stream",
    [
      Alcotest.test_case "A/B/C map take fold" `Quick test_basic_abc;
      Alcotest.test_case "from_file emits bounded chunks" `Quick
        test_from_file_chunks;
      Alcotest.test_case "take from_file closes" `Quick
        test_take_then_file_close;
      Alcotest.test_case "from_file rejects invalid chunk size" `Quick
        test_from_file_invalid_chunk_size;
      Alcotest.test_case "from_file missing path fails typed" `Quick
        test_from_file_missing_path_fails_typed;
      Alcotest.test_case "from_file error is recoverable" `Quick
        test_from_file_error_is_recoverable;
      Alcotest.test_case "from_file maps file error" `Quick
        test_from_file_map_error;
      Alcotest.test_case "from_file take zero is lazy" `Quick
        test_from_file_take_zero_is_lazy;
      Alcotest.test_case "from_file downstream failure closes" `Quick
        test_from_file_downstream_failure_closes;
      Alcotest.test_case "merge cancels upstream on downstream stop" `Quick
        test_merge_cancellation;
      Alcotest.test_case "flat_map_par is bounded concurrent" `Quick
        test_flat_map_par_concurrency;
      Alcotest.test_case "bounded queue no deadlock on early stop" `Quick
        test_bounded_queue_no_deadlock;
      Alcotest.test_case "explicit deps/error rows compose" `Quick
        test_row_pipeline_runtime;
      Alcotest.test_case "grouped batches" `Quick test_grouped_batches;
      Alcotest.test_case "mailbox closes and drops" `Quick
        test_mailbox_stream_close_and_drop;
      Alcotest.test_case "mailbox batch stream emits partial batches" `Quick
        test_mailbox_batch_stream_emits_partial;
      Alcotest.test_case "drain counter await zero" `Quick
        test_drain_counter_await_zero;
    ] )

let () = Alcotest.run "eta-stream" [ suite ]
