open From_file_research

let require condition message = if not condition then failwith message

let () =
  Eio_main.run @@ fun env ->
  let cwd = Eio.Stdenv.cwd env in
  let missing = Eio.Path.(cwd / "from-file-research-missing.tmp") in
  (try Eio.Path.unlink missing with _ -> ());

  let typed_missing = F_a_typed_default.from_file missing in
  (match typed_missing () with
  | Error (`File_error { Common.kind = `Not_found; operation = `Open; _ }) -> ()
  | _ -> failwith "typed default did not expose open/not_found");
  require
    (F_a_typed_default.recover_missing typed_missing = [])
    "typed default was not recoverable";

  let mapped = F_b_mapper_only.app_file missing in
  (match mapped () with
  | Error (`Storage { Common.kind = `Not_found; _ }) -> ()
  | _ -> failwith "mapper-only did not map into app error");

  let unsafe = F_c_unsafe_exn.from_file_unsafe missing in
  (match F_c_unsafe_exn.cannot_recover_with_typed_error unsafe with
  | Error (Eio.Io _) -> ()
  | _ -> failwith "unsafe candidate did not raise raw Eio.Io");

  let path = Eio.Path.(cwd / "from-file-research-ok.tmp") in
  Eio.Path.save ~create:(`Or_truncate 0o600) path "abcdefg";
  Fun.protect
    ~finally:(fun () -> Eio.Path.unlink path)
    (fun () ->
      (match F_a_typed_default.from_file ~chunk_size:3 path () with
      | Ok chunks ->
          require
            (List.map Bytes.to_string chunks = [ "abc"; "def"; "g" ])
            "typed default did not chunk"
      | Error (`File_error error) -> failwith error.Common.message);

      Eio.Switch.run @@ fun sw ->
      let flow = Eio.Path.open_in ~sw path in
      match
        F_d_preopened_flow.from_flow ~chunk_size:3
          ~on_read_error:(fun exn -> `Read exn)
          flow ()
      with
      | Ok chunks ->
          require
            (List.map Bytes.to_string chunks = [ "abc"; "def"; "g" ])
            "preopened flow did not chunk"
      | Error (`Read exn) -> raise exn);

  print_endline "from_file_research runtime smoke passed"
