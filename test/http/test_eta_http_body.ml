open Test_eta_http_support

let test_body_stream_release_once () =
  with_test_clock @@ fun _sw _clock rt ->
  let released = ref 0 in
  let stream =
    Eta_http.Body.Stream.of_bytes
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      [ Bytes.of_string "abc"; Bytes.of_string "def" ]
  in
  let body =
    Eta.Runtime.run rt (Eta_http.Body.Stream.read_all stream)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "abcdef" (Bytes.to_string body);
  ignore
    (Eta.Runtime.run rt (Eta_http.Body.Stream.discard stream)
    |> Eta_test.Expect.expect_ok);
  Alcotest.(check int) "release once" 1 !released

let test_body_stream_reader_release_once () =
  with_test_clock @@ fun _sw _clock rt ->
  let released = ref 0 in
  let values =
    ref
      [
        Eta_http.Body.Stream.Chunk (Bytes.of_string "a");
        Eta_http.Body.Stream.Last (Bytes.of_string "b");
      ]
  in
  let stream =
    Eta_http.Body.Stream.of_reader
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      (fun () ->
        match !values with
        | [] -> Eta.Effect.pure Eta_http.Body.Stream.End
        | next :: rest ->
            values := rest;
            Eta.Effect.pure next)
  in
  let body =
    Eta.Runtime.run rt (Eta_http.Body.Stream.read_all stream)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "ab" (Bytes.to_string body);
  ignore
    (Eta.Runtime.run rt (Eta_http.Body.Stream.discard stream)
    |> Eta_test.Expect.expect_ok);
  Alcotest.(check int) "release once" 1 !released

let rec body_stream_concurrent_use = function
  | Eta.Cause.Fail
      {
        Eta_http.Error.kind =
          Decode_error { codec = "body-stream"; message };
        _;
      } ->
      contains message "concurrent"
  | Eta.Cause.Fail _ | Eta.Cause.Die _ | Eta.Cause.Interrupt _ -> false
  | Eta.Cause.Sequential causes | Eta.Cause.Concurrent causes ->
      List.exists body_stream_concurrent_use causes
  | Eta.Cause.Finalizer _ -> false
  | Eta.Cause.Suppressed { primary; finalizer } ->
      ignore finalizer;
      body_stream_concurrent_use primary

let test_body_stream_rejects_concurrent_reads () =
  with_test_clock @@ fun _sw _clock rt ->
  let read_calls = ref 0 in
  let first_started, first_started_resolver = Eio.Promise.create () in
  let first_unblocked = ref false in
  let first_unblock, first_unblock_resolver = Eio.Promise.create () in
  let unblock_first () =
    if not !first_unblocked then (
      first_unblocked := true;
      Eio.Promise.resolve first_unblock_resolver ())
  in
  let stream =
    Eta_http.Body.Stream.of_reader (fun () ->
        Eta.Effect.sync (fun () ->
            incr read_calls;
            match !read_calls with
            | 1 ->
                Eio.Promise.resolve first_started_resolver ();
                Eio.Promise.await first_unblock;
                Eta_http.Body.Stream.Chunk (Bytes.of_string "first")
            | _ -> Eta_http.Body.Stream.Last (Bytes.of_string "second")))
  in
  let first = Eta_http.Body.Stream.read stream in
  let second =
    Eta.Effect.sync (fun () -> Eio.Promise.await first_started)
    |> Eta.Effect.bind (fun () -> Eta_http.Body.Stream.read stream)
    |> Eta.Effect.finally (Eta.Effect.sync unblock_first)
  in
  (match Eta.Runtime.run rt (Eta.Effect.par first second) with
  | Eta.Exit.Error cause when body_stream_concurrent_use cause -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected concurrent read failure: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause
  | Eta.Exit.Ok _ -> Alcotest.fail "concurrent reads both succeeded");
  Alcotest.(check int) "second read did not enter reader" 1 !read_calls

let test_body_source_owned_stream_releases_on_scope_exit () =
  with_test_clock @@ fun _sw _clock rt ->
  let released = ref 0 in
  let stream =
    Eta_http.Body.Stream.of_bytes
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      [ Bytes.of_string "abc" ]
  in
  let effect =
    Eta_http.Body.Source.with_owned_stream
      (Eta_http.Body.Source.stream stream)
      (function
        | None -> Alcotest.fail "expected owned stream"
        | Some owned ->
            Alcotest.(check (option int)) "length" None owned.length;
            Eta.Effect.unit)
  in
  ignore (Eta.Runtime.run rt effect |> Eta_test.Expect.expect_ok);
  Alcotest.(check int) "released" 1 !released

let test_body_source_rewindable_stream_is_owned_per_call () =
  with_test_clock @@ fun _sw _clock rt ->
  let made = ref 0 in
  let released = ref 0 in
  let source =
    Eta_http.Body.Source.rewindable ~length:3 (fun () ->
        incr made;
        Eta_http.Body.Stream.of_bytes
          ~release:(fun () ->
            incr released;
            Eta.Effect.unit)
          [ Bytes.of_string "abc" ])
  in
  let run_once () =
    Eta_http.Body.Source.with_owned_stream source (function
      | None -> Alcotest.fail "expected owned stream"
      | Some owned ->
          Alcotest.(check (option int)) "length" (Some 3) owned.length;
          Eta_http.Body.Stream.read_all owned.stream |> Eta.Effect.map ignore)
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  run_once ();
  run_once ();
  Alcotest.(check int) "made" 2 !made;
  Alcotest.(check int) "released" 2 !released

let test_body_stream_read_all_caps_default () =
  with_test_clock @@ fun _sw _clock rt ->
  let stream =
    Eta_http.Body.Stream.of_bytes
      [ Bytes.make body_size_cap 'a'; Bytes.of_string "b" ]
  in
  Eta.Runtime.run rt (Eta_http.Body.Stream.read_all stream)
  |> expect_body_too_large "read_all" ~limit:body_size_cap

let chunked_reader_of_string context raw =
  let offset = ref 0 in
  let fail message =
    Eta.Effect.fail
      (Eta_http.Error.make ~protocol:context.Eta_http.Body.Chunked.protocol
         ~method_:context.method_ ~uri:context.uri
         (Decode_error { codec = "chunked-fixture"; message }))
  in
  let read_exact n =
    if n < 0 then invalid_arg "read_exact";
    if !offset + n > String.length raw then fail "fixture EOF"
    else
      let chunk = Bytes.of_string (String.sub raw !offset n) in
      offset := !offset + n;
      Eta.Effect.pure chunk
  in
  let read_line ~limit =
    let rec loop index =
      if index - !offset > limit then fail "line too long"
      else if index + 1 >= String.length raw then fail "line EOF"
      else if
        Char.equal raw.[index] '\r' && Char.equal raw.[index + 1] '\n'
      then
        let line = String.sub raw !offset (index - !offset) in
        offset := index + 2;
        Eta.Effect.pure line
      else loop (index + 1)
    in
    loop !offset
  in
  { Eta_http.Body.Chunked.read_exact; read_line }

let test_chunked_decodes_trailers () =
  with_test_clock @@ fun _sw _clock rt ->
  let context =
    {
      Eta_http.Body.Chunked.protocol = Eta_http.Error.H1;
      method_ = "GET";
      uri = "http://example.test/chunked";
    }
  in
  let reader =
    chunked_reader_of_string context
      " 4 \r\nWiki\r\n 5 ;ext=1\r\npedia\r\n0\r\nX-Trailer: ok\r\n\r\n"
  in
  let decoder = Eta_http.Body.Chunked.create ~context ~reader () in
  let body =
    let rec loop acc =
      Eta_http.Body.Chunked.read decoder
      |> Eta.Effect.bind (function
           | None -> Eta.Effect.pure (Bytes.concat Bytes.empty (List.rev acc))
           | Some chunk -> loop (chunk :: acc))
    in
    Eta.Runtime.run rt (loop []) |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "decoded" "Wikipedia" (Bytes.to_string body);
  Alcotest.(check (option string))
    "trailer" (Some "ok")
    (Eta_http.Core.Header.get "x-trailer"
       (Eta_http.Body.Chunked.trailers decoder))

let test_chunked_encoder () =
  let encoded =
    Eta_http.Body.Chunked.encode_chunk (Bytes.of_string "abcdefghijklmnop")
  in
  let encoded = Bytes.concat Bytes.empty encoded |> Bytes.to_string in
  Alcotest.(check string) "chunk" "10\r\nabcdefghijklmnop\r\n" encoded;
  let trailers = Eta_http.Core.Header.unsafe_of_list [ ("x-trailer", "ok") ] in
  let last =
    Eta_http.Body.Chunked.encode_last_chunk ~trailers ()
    |> Bytes.to_string
  in
  Alcotest.(check string) "last" "0\r\nx-trailer: ok\r\n\r\n" last

let test_gzip_transducer_roundtrip () =
  with_test_clock @@ fun _sw _clock rt ->
  let input =
    Eta_http.Body.Stream.of_bytes
      [ Bytes.of_string "alpha"; Bytes.of_string "-beta"; Bytes.of_string "-gamma" ]
  in
  let encoded = Eta_http.Body.Transducer.gzip_encode input in
  let compressed =
    Eta.Runtime.run rt (Eta_http.Body.Stream.read_all encoded)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check bool) "compressed non-empty" true (Bytes.length compressed > 0);
  let decoded =
    Eta_http.Body.Transducer.gzip_decode
      (Eta_http.Body.Stream.of_bytes [ compressed ])
  in
  let body =
    Eta.Runtime.run rt (Eta_http.Body.Stream.read_all decoded)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "roundtrip" "alpha-beta-gamma" (Bytes.to_string body)

let test_gzip_transducer_expansion_cap () =
  with_test_clock @@ fun _sw _clock rt ->
  let input = Eta_http.Body.Stream.of_bytes [ Bytes.make 128 'x' ] in
  let encoded = Eta_http.Body.Transducer.gzip_encode input in
  let compressed =
    Eta.Runtime.run rt (Eta_http.Body.Stream.read_all encoded)
    |> Eta_test.Expect.expect_ok
  in
  let decoded =
    Eta_http.Body.Transducer.gzip_decode ~max_decoded_bytes:32
      (Eta_http.Body.Stream.of_bytes [ compressed ])
  in
  match Eta.Runtime.run rt (Eta_http.Body.Stream.read_all decoded) with
  | Eta.Exit.Ok _ -> Alcotest.fail "gzip expansion cap unexpectedly succeeded"
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Decode_error { codec; message }; _ }) ->
      Alcotest.(check string) "codec" "gzip" codec;
      Alcotest.(check bool) "message" true (contains message "exceeds")
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected gzip failure shape: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let gzip_compress rt value =
  let input = Eta_http.Body.Stream.of_bytes [ Bytes.of_string value ] in
  let encoded = Eta_http.Body.Transducer.gzip_encode input in
  Eta.Runtime.run rt (Eta_http.Body.Stream.read_all encoded)
  |> Eta_test.Expect.expect_ok

let expect_gzip_decode_error rt label bytes =
  let decoded =
    Eta_http.Body.Transducer.gzip_decode
      (Eta_http.Body.Stream.of_bytes [ bytes ])
  in
  match Eta.Runtime.run rt (Eta_http.Body.Stream.read_all decoded) with
  | Eta.Exit.Ok _ -> Alcotest.failf "%s unexpectedly decoded" label
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Decode_error { codec = "gzip"; _ }; _ }) ->
      ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s unexpected failure shape: %a" label
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let test_gzip_transducer_rejects_truncated_stream () =
  with_test_clock @@ fun _sw _clock rt ->
  let compressed = gzip_compress rt "truncated-body" in
  let truncated = Bytes.sub compressed 0 (Bytes.length compressed - 4) in
  expect_gzip_decode_error rt "truncated" truncated

let test_gzip_transducer_rejects_crc_mismatch () =
  with_test_clock @@ fun _sw _clock rt ->
  let compressed = gzip_compress rt "crc-body" in
  let corrupt = Bytes.copy compressed in
  let crc_offset = Bytes.length corrupt - 8 in
  Bytes.set corrupt crc_offset
    (Char.chr (Char.code (Bytes.get corrupt crc_offset) lxor 0xff));
  expect_gzip_decode_error rt "crc" corrupt

let test_gzip_transducer_decodes_concatenated_members () =
  with_test_clock @@ fun _sw _clock rt ->
  let first = gzip_compress rt "hello " in
  let second = gzip_compress rt "world" in
  let concatenated = Bytes.cat first second in
  let decoded =
    Eta_http.Body.Transducer.gzip_decode
      (Eta_http.Body.Stream.of_bytes [ concatenated ])
  in
  let body =
    Eta.Runtime.run rt (Eta_http.Body.Stream.read_all decoded)
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello world" (Bytes.to_string body)
