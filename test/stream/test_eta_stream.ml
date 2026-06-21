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
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()
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

let test_from_file_chunks () =
  with_runtime @@ fun env rt ->
  with_file env "stream-chunks.tmp" "abcdefg" @@ fun path ->
  match
    Eta_stream.Stream.from_file ~chunk_size:3 path |> run_collect |> Runtime.run rt
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
    Eta_stream.Stream.from_file ~chunk_size:4096 path
    |> Eta_stream.Stream.take 1
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

let test_take_while_then_file_close () =
  with_runtime @@ fun env rt ->
  let large = String.make (1024 * 1024) 'x' in
  with_file env "stream-take-while-close.tmp" large @@ fun path ->
  let before = fd_count () in
  let seen = ref 0 in
  let result =
    Eta_stream.Stream.from_file ~chunk_size:4096 path
    |> Eta_stream.Stream.take_while (fun _chunk ->
           incr seen;
           !seen = 1)
    |> run_collect
    |> Runtime.run rt
  in
  (match result with
  | Exit.Ok [ chunk ] ->
      Alcotest.(check int) "one bounded chunk" 4096 (Bytes.length chunk);
      Alcotest.(check int) "predicate saw stop boundary" 2 !seen
  | Exit.Ok chunks ->
      Alcotest.failf "expected one chunk, got %d" (List.length chunks)
  | Exit.Error cause ->
      Alcotest.failf "take_while from_file failed: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause);
  let after = fd_count () in
  if before >= 0 && after > before then
    Alcotest.failf
      "fd count grew after from_file early take_while: before=%d after=%d"
      before after

let test_filter_map_take_then_file_close () =
  with_runtime @@ fun env rt ->
  let large = String.make (1024 * 1024) 'x' in
  with_file env "stream-filter-map-take-close.tmp" large @@ fun path ->
  let before = fd_count () in
  let seen = ref 0 in
  let result =
    Eta_stream.Stream.from_file ~chunk_size:4096 path
    |> Eta_stream.Stream.filter_map (fun chunk ->
           incr seen;
           Some chunk)
    |> Eta_stream.Stream.take 1
    |> run_collect
    |> Runtime.run rt
  in
  (match result with
  | Exit.Ok [ chunk ] ->
      Alcotest.(check int) "one bounded chunk" 4096 (Bytes.length chunk);
      Alcotest.(check int) "mapper stopped after take" 1 !seen
  | Exit.Ok chunks ->
      Alcotest.failf "expected one chunk, got %d" (List.length chunks)
  | Exit.Error cause ->
      Alcotest.failf "filter_map take from_file failed: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause);
  let after = fd_count () in
  if before >= 0 && after > before then
    Alcotest.failf
      "fd count grew after from_file filter_map take: before=%d after=%d"
      before after

let test_changes_take_then_file_close () =
  with_runtime @@ fun env rt ->
  let large = String.make (1024 * 1024) 'x' in
  with_file env "stream-changes-take-close.tmp" large @@ fun path ->
  let before = fd_count () in
  let seen = ref 0 in
  let result =
    Eta_stream.Stream.from_file ~chunk_size:4096 path
    |> Eta_stream.Stream.tap (fun _chunk ->
           Effect.sync (fun () -> incr seen))
    |> Eta_stream.Stream.changes
    |> Eta_stream.Stream.take 1
    |> run_collect
    |> Runtime.run rt
  in
  (match result with
  | Exit.Ok [ chunk ] ->
      Alcotest.(check int) "one bounded chunk" 4096 (Bytes.length chunk);
      Alcotest.(check int) "source stopped after take" 1 !seen
  | Exit.Ok chunks ->
      Alcotest.failf "expected one chunk, got %d" (List.length chunks)
  | Exit.Error cause ->
      Alcotest.failf "changes take from_file failed: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause);
  let after = fd_count () in
  if before >= 0 && after > before then
    Alcotest.failf
      "fd count grew after from_file changes take: before=%d after=%d"
      before after

let test_from_file_invalid_chunk_size () =
  Eio_main.run @@ fun env ->
  let path = Eio.Path.(Eio.Stdenv.cwd env / "unused-stream-file.tmp") in
  try
    ignore (Eta_stream.Stream.from_file ~chunk_size:0 path);
    Alcotest.fail "from_file accepted chunk_size=0"
  with Invalid_argument _ -> ()

let test_from_file_missing_path_fails_typed () =
  with_runtime @@ fun env rt ->
  let path = Eio.Path.(Eio.Stdenv.cwd env / "missing-stream-file.tmp") in
  (try Eio.Path.unlink path with _ -> ());
  match Eta_stream.Stream.from_file path |> run_drain |> Runtime.run rt with
  | Exit.Ok () -> Alcotest.fail "missing file unexpectedly succeeded"
  | Exit.Error
      (Cause.Fail
        (`File_error
          {
            Eta_stream.Stream.kind = `Not_found;
            operation = `Open;
            diagnostic;
            _;
          })) ->
      Alcotest.(check bool) "diagnostic is present" true
        (String.length diagnostic > 0)
  | Exit.Error cause ->
      Alcotest.failf "missing file produced unexpected cause: %a"
        (Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause

let test_from_file_error_is_recoverable () =
  with_runtime @@ fun env rt ->
  let path = Eio.Path.(Eio.Stdenv.cwd env / "missing-stream-file-recover.tmp") in
  (try Eio.Path.unlink path with _ -> ());
  let eff =
    Eta_stream.Stream.from_file path |> run_drain
    |> Effect.catch (function
         | `File_error { Eta_stream.Stream.kind = `Not_found; _ } -> Effect.unit
         | error -> Effect.fail error)
  in
  Runtime.run rt eff |> check_ok_unit "recover missing file"

let test_from_file_map_error () =
  with_runtime @@ fun env rt ->
  let path = Eio.Path.(Eio.Stdenv.cwd env / "missing-stream-file-map.tmp") in
  (try Eio.Path.unlink path with _ -> ());
  match
    Eta_stream.Stream.from_file_map_error ~on_error:(fun error -> `Storage error) path
    |> run_drain |> Runtime.run rt
  with
  | Exit.Error
      (Cause.Fail (`Storage { Eta_stream.Stream.kind = `Not_found; operation = `Open; _ }))
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
  Eta_stream.Stream.from_file path |> Eta_stream.Stream.take 0 |> run_drain |> Runtime.run rt
  |> check_ok_unit "take zero does not open file"

let test_from_file_downstream_failure_closes () =
  with_runtime @@ fun env rt ->
  let large = String.make (1024 * 1024) 'x' in
  with_file env "stream-downstream-failure.tmp" large (fun path ->
      let before = fd_count () in
      let eff =
        Eta_stream.Stream.from_file ~chunk_size:4096 path
        |> Eta_stream.Stream.map_effect (fun _ -> Effect.fail `Stop)
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

let suite =
  ( "Eta_stream",
    [
      Alcotest.test_case "from_file emits bounded chunks" `Quick
        test_from_file_chunks;
      Alcotest.test_case "take from_file closes" `Quick
        test_take_then_file_close;
      Alcotest.test_case "take_while from_file closes" `Quick
        test_take_while_then_file_close;
      Alcotest.test_case "filter_map take from_file closes" `Quick
        test_filter_map_take_then_file_close;
      Alcotest.test_case "changes take from_file closes" `Quick
        test_changes_take_then_file_close;
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
    ] )

let () = Alcotest.run "eta-stream" [ suite ]
