module E = Eta.Effect
module H = Eta_http
module M = H.Multipart

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (M.error_message error)

let concat chunks =
  let length =
    List.fold_left (fun total chunk -> total + Bytes.length chunk) 0 chunks
  in
  let result = Bytes.create length in
  ignore
    (List.fold_left
       (fun offset chunk ->
         Bytes.blit chunk 0 result offset (Bytes.length chunk);
         offset + Bytes.length chunk)
       0 chunks);
  result

let stream_of_body = function
  | H.Request.Stream stream -> stream
  | H.Request.One_shot_stream { stream; _ } -> stream
  | H.Request.Rewindable_stream { make; _ } -> make ()
  | H.Request.Empty | H.Request.Fixed _ ->
      Alcotest.fail "expected multipart stream"

let run program =
  let outcome = Eta_test.Run.run program in
  Eta_test.Run.expect_no_pending_fibers outcome;
  outcome.exit

let collect_stream stream = run (H.Body.Stream.read_all ~max_bytes:1_000_000 stream)

let collect_body = function
  | H.Request.Fixed chunks -> Eta.Exit.Ok (concat chunks)
  | body -> collect_stream (stream_of_body body)

let bytes_exit = function
  | Eta.Exit.Ok bytes -> bytes
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected multipart failure: %a"
        (Eta.Cause.pp H.Error.pp)
        cause

let contains value needle =
  let value = Bytes.to_string value in
  let rec loop offset =
    offset + String.length needle <= String.length value
    &&
    (String.equal needle (String.sub value offset (String.length needle))
    || loop (offset + 1))
  in
  String.length needle = 0 || loop 0

let count_occurrences value needle =
  let value = Bytes.to_string value in
  let rec loop offset count =
    if offset + String.length needle > String.length value then count
    else if String.equal needle (String.sub value offset (String.length needle))
    then loop (offset + String.length needle) (count + 1)
    else loop (offset + 1) count
  in
  loop 0 0

let test_multipart_rejects_empty_and_injection () =
  Alcotest.(check bool) "empty" true (M.make [] = Error M.Empty);
  let invalid parts expected =
    match M.make parts with
    | Error error -> Alcotest.(check bool) "typed error" true (error = expected)
    | Ok _ -> Alcotest.fail "unsafe multipart input was accepted"
  in
  invalid [ M.Text { name = "bad\rname"; value = "x" } ]
    (M.Invalid_disposition "field name");
  invalid
    [
      M.File
        {
          name = "file";
          filename = "bad\"name";
          content_type = "audio/wav";
          data = M.Buffered Bytes.empty;
        };
    ]
    (M.Invalid_disposition "filename");
  invalid
    [
      M.File
        {
          name = "file";
          filename = "a.wav";
          content_type = "audio/wav\nInjected: yes";
          data = M.Buffered Bytes.empty;
        };
    ]
    (M.Invalid_header "content type");
  invalid
    [
      M.File
        {
          name = "file";
          filename = "a.wav";
          content_type = "audio/wav";
          data =
            M.Pull
              {
                length = Some (-1L);
                replayability = M.Replayable;
                open_reader = (fun () -> fun () -> None);
              };
        };
    ]
    (M.Impossible_shape "a source length must not be negative")

let buffered_parts data =
  [
    M.Text { name = "model"; value = "whisper-1" };
    M.File
      {
        name = "file";
        filename = "a.bin";
        content_type = "application/octet-stream";
        data = M.Buffered data;
      };
  ]

let test_multipart_buffered_deterministic_collision_free () =
  let data = Bytes.of_string "abc" in
  let first = require_ok (M.make (buffered_parts data)) in
  let second = require_ok (M.make (buffered_parts data)) in
  Alcotest.(check bool) "buffered Eta boundary prefix" true
    (String.starts_with ~prefix:"eta-http-" first.boundary);
  Alcotest.(check string) "deterministic" first.boundary second.boundary;
  let anchor = M.Text { name = "seed"; value = "stable-anchor" } in
  let anchor_file =
    M.File
      {
        name = "anchor-file";
        filename = "anchor.bin";
        content_type = "application/octet-stream";
        data = M.Buffered data;
      }
  in
  let candidate =
    require_ok
      (M.make
         [
           anchor;
           M.Text { name = "note"; value = "ordinary" };
           anchor_file;
         ])
  in
  let colliding =
    [
      anchor;
      M.Text { name = "note"; value = candidate.boundary };
      anchor_file;
    ]
  in
  let avoided = require_ok (M.make colliding) in
  Alcotest.(check bool) "candidate replaced" true
    (not (String.equal candidate.boundary avoided.boundary));
  let encoded = collect_body avoided.body |> bytes_exit in
  Alcotest.(check bool) "selected boundary absent from field value" false
    (contains (Bytes.of_string candidate.boundary) avoided.boundary);
  Alcotest.(check bool) "selected boundary frames body" true
    (contains encoded ("--" ^ avoided.boundary));
  let boundary = candidate.boundary in
  let file ?(name = "file") ?(filename = "file.bin")
      ?(content_type = "application/octet-stream") data =
    M.File
      {
        name;
        filename;
        content_type;
        data = M.Buffered data;
      }
  in
  let forced_locations =
    [
      ("text name", [ anchor; M.Text { name = boundary; value = "value" } ]);
      ("text value", [ anchor; M.Text { name = "name"; value = boundary } ]);
      ( "file name",
        [ anchor; file ~name:boundary (Bytes.of_string "payload") ] );
      ( "filename",
        [ anchor; file ~filename:boundary (Bytes.of_string "payload") ] );
      ( "content type",
        [ anchor; file ~content_type:boundary (Bytes.of_string "payload") ] );
      ( "first buffered payload",
        [
          anchor;
          file ~name:"first" (Bytes.of_string boundary);
          file ~name:"second" (Bytes.of_string "safe-second");
        ] );
      ( "second buffered payload",
        [
          anchor;
          file ~name:"first" (Bytes.of_string "safe-first");
          file ~name:"second" (Bytes.of_string boundary);
        ] );
    ]
  in
  List.iter
    (fun (location, parts) ->
      let multipart = require_ok (M.make parts) in
      Alcotest.(check bool) (location ^ " forced candidate replaced") true
        (not (String.equal boundary multipart.boundary)))
    forced_locations;
  let payload_a = Bytes.of_string "first-payload" in
  let payload_b = Bytes.of_string "second-payload" in
  let every_static_location =
    [
      M.Text { name = "text-name"; value = "text-value" };
      M.File
        {
          name = "file-name-a";
          filename = "filename-a.bin";
          content_type = "application/x-first";
          data = M.Buffered payload_a;
        };
      M.File
        {
          name = "file-name-b";
          filename = "filename-b.bin";
          content_type = "application/x-second";
          data = M.Buffered payload_b;
        };
    ]
  in
  let static = require_ok (M.make every_static_location) in
  (match static.body with
  | H.Request.Fixed _ -> ()
  | _ -> Alcotest.fail "buffered multipart did not produce Request.Fixed");
  List.iter
    (fun value ->
      Alcotest.(check bool)
        ("boundary absent from static value " ^ value)
        false
        (contains (Bytes.of_string value) static.boundary))
    [
      "text-name";
      "text-value";
      "file-name-a";
      "filename-a.bin";
      "application/x-first";
      "file-name-b";
      "filename-b.bin";
      "application/x-second";
    ];
  List.iteri
    (fun index payload ->
      Alcotest.(check bool)
        (Printf.sprintf "boundary absent from buffered payload %d" index)
        false (contains payload static.boundary))
    [ payload_a; payload_b ]

let test_multipart_buffered_exact_bytes_and_order () =
  let file = Bytes.of_string "\000\255binary" in
  let multipart = require_ok (M.make (buffered_parts file)) in
  let expected =
    concat
      [
        Bytes.of_string
          ("--" ^ multipart.boundary
         ^ "\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n");
        Bytes.of_string "whisper-1\r\n";
        Bytes.of_string
          ("--" ^ multipart.boundary
         ^ "\r\nContent-Disposition: form-data; name=\"file\"; \
            filename=\"a.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n");
        file;
        Bytes.of_string "\r\n";
        Bytes.of_string ("--" ^ multipart.boundary ^ "--\r\n");
      ]
  in
  let actual = collect_body multipart.body |> bytes_exit in
  Alcotest.(check bytes) "exact multipart bytes" expected actual;
  Alcotest.(check (option int64)) "exact buffered length"
    (Some (Int64.of_int (Bytes.length expected)))
    multipart.content_length

let pull_source ?length ~replayability opened chunks =
  {
    M.length;
    replayability;
    open_reader =
      (fun () ->
        incr opened;
        let chunks = ref chunks in
        fun () ->
          match !chunks with
          | [] -> None
          | chunk :: rest ->
              chunks := rest;
              Some chunk);
  }

let stream_part source =
  M.File
    {
      name = "file";
      filename = "a.bin";
      content_type = "application/octet-stream";
      data = M.Pull source;
    }

let test_multipart_stream_lazy_lengths_and_replayability () =
  let chunks = [ Bytes.of_string "ab"; Bytes.empty; Bytes.of_string "cde" ] in
  let opened = ref 0 in
  let known =
    require_ok
      (M.make
         [
           stream_part
             (pull_source ~length:5L ~replayability:M.Replayable opened chunks);
         ])
  in
  Alcotest.(check int) "known source remains closed" 0 !opened;
  let expected_length =
    collect_body known.body |> bytes_exit |> Bytes.length |> Int64.of_int
  in
  Alcotest.(check int) "first replayable open" 1 !opened;
  Alcotest.(check (option int64)) "known exact content length"
    (Some expected_length) known.content_length;
  ignore (collect_body known.body |> bytes_exit);
  Alcotest.(check int) "fresh reader on retry" 2 !opened;
  let unknown_opened = ref 0 in
  let unknown =
    require_ok
      (M.make
         [
           stream_part
             (pull_source ~replayability:M.Replayable unknown_opened chunks);
         ])
  in
  Alcotest.(check (option int64)) "unknown content length" None
    unknown.content_length;
  Alcotest.(check int) "unknown source remains closed" 0 !unknown_opened;
  ignore (collect_body unknown.body |> bytes_exit);
  Alcotest.(check int) "unknown source opens during read" 1 !unknown_opened;
  let once_opened = ref 0 in
  let once =
    require_ok
      (M.make
         [
           stream_part
             (pull_source ~length:5L ~replayability:M.One_shot once_opened
                chunks);
         ])
  in
  (match once.body with
  | H.Request.One_shot_stream { length; _ } ->
      Alcotest.(check int64) "known one-shot total"
        (Option.get once.content_length)
        (Int64.of_int length)
  | _ ->
      Alcotest.fail
        "known one-shot multipart did not produce Request.One_shot_stream");
  ignore (collect_body once.body |> bytes_exit);
  ignore (collect_body once.body |> bytes_exit);
  Alcotest.(check int) "one-shot source opened once" 1 !once_opened

let expect_codec codec = function
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { H.Error.kind = H.Error.Decode_error { codec = actual; _ }; _ }) ->
      Alcotest.(check string) "error codec" codec actual
  | Eta.Exit.Ok _ -> Alcotest.fail "expected typed multipart stream failure"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected multipart cause: %a"
        (Eta.Cause.pp H.Error.pp)
        cause

let test_multipart_source_failures_and_overflow () =
  let open_failure =
    {
      M.length = None;
      replayability = M.Replayable;
      open_reader = (fun () -> failwith "open failed");
    }
  in
  let open_failure = require_ok (M.make [ stream_part open_failure ]) in
  open_failure.body |> stream_of_body |> collect_stream
  |> expect_codec "multipart-source";
  let read_failure =
    {
      M.length = None;
      replayability = M.Replayable;
      open_reader = (fun () -> fun () -> failwith "read failed");
    }
  in
  let read_failure = require_ok (M.make [ stream_part read_failure ]) in
  read_failure.body |> stream_of_body |> collect_stream
  |> expect_codec "multipart-source";
  let overflow =
    {
      M.length = Some Int64.max_int;
      replayability = M.Replayable;
      open_reader = (fun () -> fun () -> None);
    }
  in
  match M.make [ stream_part overflow ] with
  | Error M.Length_overflow -> ()
  | Error error -> Alcotest.fail (M.error_message error)
  | Ok _ -> Alcotest.fail "overflowing multipart length was accepted"

let expect_source_length_message expected = function
  | Eta.Exit.Error
      (Eta.Cause.Fail
        {
          H.Error.kind =
            H.Error.Decode_error
              { codec = "multipart-source-length"; message };
          _;
        }) ->
      Alcotest.(check string) "source length message" expected message
  | Eta.Exit.Ok _ -> Alcotest.fail "expected multipart source length failure"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected source length cause: %a"
        (Eta.Cause.pp H.Error.pp)
        cause

let declared_source ~length ~replayability chunks =
  {
    M.length = Some length;
    replayability;
    open_reader =
      (fun () ->
        let chunks = ref chunks in
        fun () ->
          match !chunks with
          | [] -> None
          | chunk :: rest ->
              chunks := rest;
              Some chunk);
  }

let test_multipart_declared_source_lengths () =
  let exact =
    require_ok
      (M.make
         [
           stream_part
             (declared_source ~length:3L ~replayability:M.Replayable
                [ Bytes.of_string "a"; Bytes.empty; Bytes.of_string "bc" ]);
         ])
  in
  ignore (collect_body exact.body |> bytes_exit);
  let exact_zero =
    require_ok
      (M.make
         [
           stream_part
             (declared_source ~length:0L ~replayability:M.Replayable
                [ Bytes.empty ]);
         ])
  in
  ignore (collect_body exact_zero.body |> bytes_exit);
  let undershoot =
    require_ok
      (M.make
         [
           stream_part
             (declared_source ~length:4L ~replayability:M.Replayable
                [ Bytes.of_string "abc" ]);
         ])
  in
  collect_stream (stream_of_body undershoot.body)
  |> expect_source_length_message "source ended before its declared length";
  let overshoot =
    require_ok
      (M.make
         [
           stream_part
             (declared_source ~length:2L ~replayability:M.Replayable
                [ Bytes.of_string "abc" ]);
         ])
  in
  collect_stream (stream_of_body overshoot.body)
  |> expect_source_length_message "source chunk exceeds its declared length";
  let second_undershoots =
    require_ok
      (M.make
         [
           stream_part
             (declared_source ~length:1L ~replayability:M.Replayable
                [ Bytes.of_string "a" ]);
           stream_part
             (declared_source ~length:2L ~replayability:M.Replayable
                [ Bytes.of_string "b" ]);
         ])
  in
  collect_stream (stream_of_body second_undershoots.body)
  |> expect_source_length_message "source ended before its declared length"

let test_multipart_mixed_source_shape () =
  let replayable_known =
    declared_source ~length:1L ~replayability:M.Replayable
      [ Bytes.of_string "a" ]
  in
  let one_shot_known =
    declared_source ~length:1L ~replayability:M.One_shot
      [ Bytes.of_string "b" ]
  in
  let unknown replayability value =
    {
      M.length = None;
      replayability;
      open_reader =
        (fun () ->
          let value = ref (Some (Bytes.of_string value)) in
          fun () ->
            let result = !value in
            value := None;
            result);
    }
  in
  let known_mixed =
    require_ok
      (M.make [ stream_part replayable_known; stream_part one_shot_known ])
  in
  (match known_mixed.body with
  | H.Request.One_shot_stream { length; _ } ->
      Alcotest.(check int64) "known mixed exact total"
        (Option.get known_mixed.content_length)
        (Int64.of_int length)
  | _ -> Alcotest.fail "mixed replayability must remain one-shot");
  let unknown_mixed =
    require_ok
      (M.make
         [
           stream_part replayable_known;
           stream_part (unknown M.One_shot "b");
         ])
  in
  Alcotest.(check (option int64)) "one unknown makes total unknown" None
    unknown_mixed.content_length;
  (match unknown_mixed.body with
  | H.Request.Stream _ -> ()
  | _ -> Alcotest.fail "unknown one-shot mix must use Request.Stream");
  let replayable_unknown =
    require_ok
      (M.make
         [
           stream_part replayable_known;
           stream_part (unknown M.Replayable "b");
         ])
  in
  Alcotest.(check (option int64)) "all replayable unknown total" None
    replayable_unknown.content_length;
  (match replayable_unknown.body with
  | H.Request.Rewindable_stream { length = None; _ } -> ()
  | _ -> Alcotest.fail "all replayable pulls must be rewindable")

let emitted_until_failure stream =
  let rec loop chunks =
    H.Body.Stream.read stream
    |> E.bind (function
         | None -> E.pure (`Ended (concat (List.rev chunks)))
         | Some chunk -> loop (chunk :: chunks))
    |> E.bind_error (fun error ->
           E.pure (`Failed (concat (List.rev chunks), error)))
  in
  run (loop [])

let test_multipart_length_precedes_collision_on_overrun () =
  let boundary = ref "" in
  let source =
    {
      M.length = Some 0L;
      replayability = M.Replayable;
      open_reader =
        (fun () ->
          let chunk = ref (Some (Bytes.of_string ("--" ^ !boundary))) in
          fun () ->
            let result = !chunk in
            chunk := None;
            result);
    }
  in
  let multipart = require_ok (M.make [ stream_part source ]) in
  boundary := multipart.boundary;
  match emitted_until_failure (stream_of_body multipart.body) with
  | Eta.Exit.Ok (`Failed (emitted, error)) ->
      (match error.H.Error.kind with
      | H.Error.Decode_error
          {
            codec = "multipart-source-length";
            message = "source chunk exceeds its declared length";
          } ->
          ()
      | _ -> Alcotest.fail "collision incorrectly won over source overrun");
      Alcotest.(check int) "no overrun delimiter emitted" 0
        (count_occurrences emitted ("\r\n--" ^ multipart.boundary))
  | Eta.Exit.Ok (`Ended _) -> Alcotest.fail "overrun collision was accepted"
  | Eta.Exit.Error cause ->
      Alcotest.failf "precedence observer failed: %a"
        (Eta.Cause.pp H.Error.pp)
        cause

let test_multipart_stream_boundary_fresh_and_static_safe () =
  let source =
    {
      M.length = Some 0L;
      replayability = M.Replayable;
      open_reader = (fun () -> fun () -> None);
    }
  in
  let parts =
    [
      M.Text { name = "metadata"; value = "eta-http-static-value" };
      stream_part source;
    ]
  in
  let first = require_ok (M.make parts) in
  let second = require_ok (M.make parts) in
  Alcotest.(check bool) "prefix" true
    (String.starts_with ~prefix:"eta-http-" first.boundary);
  Alcotest.(check bool) "fresh" true
    (not (String.equal first.boundary second.boundary));
  Alcotest.(check bool) "static value noncollision" false
    (contains (Bytes.of_string "eta-http-static-value") first.boundary)

let test_multipart_stream_boundaries_concurrent_unique () =
  let make_boundaries () =
    List.init 32 (fun _ ->
        let source =
          {
            M.length = None;
            replayability = M.Replayable;
            open_reader = (fun () -> fun () -> None);
          }
        in
        (require_ok (M.make [ stream_part source ])).boundary)
  in
  let domains =
    List.init 8 (fun _ ->
        (Domain.spawn
           [@alert "-do_not_spawn_domains"]
           [@alert "-unsafe_multidomain"])
          make_boundaries)
  in
  let boundaries = List.concat_map Domain.join domains in
  let unique = Hashtbl.create (List.length boundaries) in
  List.iter (fun boundary -> Hashtbl.replace unique boundary ()) boundaries;
  Alcotest.(check int) "all concurrent boundaries are unique"
    (List.length boundaries) (Hashtbl.length unique);
  List.iter
    (fun boundary ->
      Alcotest.(check int) "128-bit token length"
        (String.length "eta-http-" + 32)
        (String.length boundary))
    boundaries

let test_multipart_collision_split_at_every_offset () =
  let boundary = ref "" in
  let split = ref 0 in
  let source =
    {
      M.length = None;
      replayability = M.Replayable;
      open_reader =
        (fun () ->
          let delimiter = "\r\n--" ^ !boundary in
          let payload = "before" ^ delimiter ^ "after" in
          let cut = String.length "before" + !split in
          let chunks =
            ref
              [
                Bytes.of_string (String.sub payload 0 cut);
                Bytes.of_string
                  (String.sub payload cut (String.length payload - cut));
              ]
          in
          fun () ->
            match !chunks with
            | [] -> None
            | chunk :: rest ->
                chunks := rest;
                Some chunk);
    }
  in
  let multipart = require_ok (M.make [ stream_part source ]) in
  boundary := multipart.boundary;
  let delimiter = "\r\n--" ^ multipart.boundary in
  for offset = 0 to String.length delimiter do
    split := offset;
    match emitted_until_failure (stream_of_body multipart.body) with
    | Eta.Exit.Ok (`Failed (emitted, error)) ->
        Alcotest.(check string) "collision codec" "multipart-boundary"
          (match error.H.Error.kind with
          | H.Error.Decode_error { codec; _ } -> codec
          | _ -> H.Error.kind_name error.kind);
        Alcotest.(check bool)
          (Printf.sprintf "delimiter not emitted at split %d" offset)
          false (contains emitted delimiter)
    | Eta.Exit.Ok (`Ended _) ->
        Alcotest.failf "collision at split %d was accepted" offset
    | Eta.Exit.Error cause ->
        Alcotest.failf "collision observer failed at split %d: %a" offset
          (Eta.Cause.pp H.Error.pp)
          cause
  done

let collision_codec error =
  match error.H.Error.kind with
  | H.Error.Decode_error { codec = "multipart-boundary"; _ } -> true
  | _ -> false

let test_multipart_source_start_collision_every_partition () =
  let boundary = ref "" in
  let split = ref 0 in
  let source =
    {
      M.length = None;
      replayability = M.Replayable;
      open_reader =
        (fun () ->
          let token = Bytes.of_string ("--" ^ !boundary) in
          let chunks =
            ref
              [
                Bytes.sub token 0 !split;
                Bytes.sub token !split (Bytes.length token - !split);
              ]
          in
          fun () ->
            match !chunks with
            | [] -> None
            | chunk :: rest ->
                chunks := rest;
                Some chunk);
    }
  in
  let multipart = require_ok (M.make [ stream_part source ]) in
  boundary := multipart.boundary;
  let token = "--" ^ multipart.boundary in
  for offset = 0 to String.length token do
    split := offset;
    match emitted_until_failure (stream_of_body multipart.body) with
    | Eta.Exit.Ok (`Failed (emitted, error)) ->
        Alcotest.(check bool) "typed source-start collision" true
          (collision_codec error);
        Alcotest.(check int)
          (Printf.sprintf "no wire delimiter at source-start split %d" offset)
          0
          (count_occurrences emitted ("\r\n--" ^ multipart.boundary))
    | Eta.Exit.Ok (`Ended _) ->
        Alcotest.failf "source-start collision split %d was accepted" offset
    | Eta.Exit.Error cause ->
        Alcotest.failf "source-start observer split %d failed: %a" offset
          (Eta.Cause.pp H.Error.pp)
          cause
  done

let test_multipart_source_start_collision_every_file_position () =
  List.iter
    (fun colliding_index ->
      let boundary = ref "" in
      let source index =
        {
          M.length = None;
          replayability = M.Replayable;
          open_reader =
            (fun () ->
              let chunks =
                ref
                  [
                    Bytes.of_string
                      (if index = colliding_index then "--" ^ !boundary
                       else Printf.sprintf "safe-%d" index);
                  ]
              in
              fun () ->
                match !chunks with
                | [] -> None
                | chunk :: rest ->
                    chunks := rest;
                    Some chunk);
        }
      in
      let parts =
        List.init 3 (fun index ->
            M.File
              {
                name = Printf.sprintf "file-%d" index;
                filename = Printf.sprintf "%d.bin" index;
                content_type = "application/octet-stream";
                data = M.Pull (source index);
              })
      in
      let multipart = require_ok (M.make parts) in
      boundary := multipart.boundary;
      match emitted_until_failure (stream_of_body multipart.body) with
      | Eta.Exit.Ok (`Failed (emitted, error)) ->
          Alcotest.(check bool) "typed positional collision" true
            (collision_codec error);
          Alcotest.(check int)
            (Printf.sprintf "only expected framing before file %d" colliding_index)
            colliding_index
            (count_occurrences emitted ("\r\n--" ^ multipart.boundary))
      | Eta.Exit.Ok (`Ended _) ->
          Alcotest.failf "source-start collision in file %d was accepted"
            colliding_index
      | Eta.Exit.Error cause ->
          Alcotest.failf "source-start file %d observer failed: %a"
            colliding_index
            (Eta.Cause.pp H.Error.pp)
            cause)
    [ 0; 1; 2 ]
