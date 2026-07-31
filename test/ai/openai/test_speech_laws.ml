module A = Eta_ai
module E = Eta.Effect
module H = Eta_http
module O = Eta_ai_openai

let qcheck_seed = Random.State.make [| 0x05ee; 0x0a0d10 |]
let count = 25

let request ?instructions input =
  O.Audio.Text_to_speech.request
    ~model:O.Audio.Text_to_speech.Gpt_4o_mini_tts ~input
    ~voice:(O.Audio.Voices.Built_in O.Audio.Voices.Alloy)
    ?instructions ~stream_format:O.Audio.Text_to_speech.Sse ()

let audio_request () =
  O.Audio.Text_to_speech.request
    ~model:O.Audio.Text_to_speech.Gpt_4o_mini_tts ~input:"generated"
    ~voice:(O.Audio.Voices.Built_in O.Audio.Voices.Alloy)
    ~stream_format:O.Audio.Text_to_speech.Audio ()

let require_ok = function Ok value -> value | Error _ -> assert false

let zero_stats =
  {
    H.Client.protocol = H.Client.H1;
    active = 0;
    idle = 0;
    capacity = 0;
    opened = 0;
    released = 0;
  }

let client response =
  H.Client.make_custom ~protocol:H.Client.H1
    ~request:(fun _ -> E.pure response)
    ~stats:(fun () -> E.pure (Some zero_stats))
    ~shutdown:(fun () -> E.unit)

let partition seeds raw =
  let length = String.length raw in
  match seeds with
  | [] -> [ Bytes.of_string raw ]
  | _ ->
      let sizes = Array.of_list seeds in
      let rec loop offset index chunks =
        if offset = length then List.rev chunks
        else
          let seed = sizes.(index mod Array.length sizes) in
          let size = 1 + abs (seed mod 17) in
          let size = min size (length - offset) in
          loop (offset + size) (index + 1)
            (Bytes.of_string (String.sub raw offset size) :: chunks)
      in
      loop 0 0 []

let run_event ?(max_buffer_bytes = 4096) ?(max_json_bytes = 4096)
    ?(max_pending_events = 16) chunks =
  let releases = ref 0 in
  let body =
    H.Body.Stream.of_bytes
      ~release:(fun () -> E.sync (fun () -> incr releases))
      chunks
  in
  let operation =
    O.Audio.Text_to_speech.stream_events ~max_buffer_bytes ~max_json_bytes
      ~max_pending_events (client (H.Response.make ~status:200 ~body ()))
      ~api_key:(A.api_key "key") (require_ok (request "generated"))
    |> E.bind (fun stream ->
           O.Audio.Text_to_speech.read_event stream
           |> E.bind (function
                | None -> E.pure None
                | Some event ->
                    O.Audio.Text_to_speech.read_event stream
                    |> E.map (fun _ -> Some event)))
  in
  let outcome = Eta_test.Run.run operation in
  Eta_test.Run.expect_no_pending_fibers outcome;
  Gc.full_major ();
  (outcome.exit, !releases)

let check_decode = function
  | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Decode _)) -> true
  | Eta.Exit.Ok _ | Eta.Exit.Error _ -> false

let check_limit kind = function
  | Eta.Exit.Error
      (Eta.Cause.Fail (O.Error.Limit_exceeded { kind = actual; _ })) ->
      String.contains actual kind
  | Eta.Exit.Ok _ | Eta.Exit.Error _ -> false

let pp_event_exit fmt = function
  | Eta.Exit.Ok None -> Format.pp_print_string fmt "Ok None"
  | Eta.Exit.Ok (Some (O.Audio.Text_to_speech.Unknown { type_; _ })) ->
      Format.fprintf fmt "Ok Unknown(%S)" type_
  | Eta.Exit.Error cause -> Eta.Cause.pp O.Error.pp fmt cause

let generated_event_json type_ value =
  `Assoc
    [
      ("type", `String type_);
      ("sequence", `Int value);
      ("enabled", `Bool (value mod 2 = 0));
      ("label", `String (Printf.sprintf "value-%d" value));
      ( "nested",
        `Assoc
          [
            ( "items",
              `List
                [
                  `Int (value + 1);
                  `String (Printf.sprintf "item-%d" (value + 2));
                  `Assoc
                    [
                      ("flag", `Bool (value mod 3 = 0));
                      ("missing", `Null);
                    ];
                ] );
            ("metadata", `Assoc [ ("revision", `Int (value + 3)) ]);
          ] );
    ]

let multiline_payload raw =
  let split = String.index raw ',' + 1 in
  String.sub raw 0 split ^ "\n"
  ^ String.sub raw split (String.length raw - split)

let sse_classes value =
  let unknown name type_ frame =
    let raw = A.Json.compact (generated_event_json type_ value) in
    let expected =
      match A.Json.parse raw with Ok json -> json | Error _ -> assert false
    in
    (name, type_, frame raw, `Unknown expected)
  in
  [
    unknown "lf-colon" "speech.lf" (fun raw -> "data:" ^ raw ^ "\n\n");
    unknown "cr-space-bom" "speech.cr" (fun raw ->
        "\xef\xbb\xbfdata: " ^ raw ^ "\r\r");
    unknown "crlf-comment-ignored" "speech.crlf" (fun raw ->
        ":comment\r\nignored:value\r\nevent:future\r\ndata: " ^ raw
        ^ "\r\n\r\n");
    unknown "mixed-multiline" "speech.mixed" (fun raw ->
        let raw = multiline_payload raw in
        match String.index_opt raw '\n' with
        | None -> assert false
        | Some split ->
            ":comment\rignored\n"
            ^ "data: "
            ^ String.sub raw 0 split
            ^ "\r\ndata: "
            ^ String.sub raw (split + 1) (String.length raw - split - 1)
            ^ "\n\r");
    ("empty-colon", "", "data:\n\n", `Decode);
    ("empty-colonless", "", "data\r\r", `Decode);
    ( "incomplete-eof",
      "",
      "data: "
      ^ A.Json.compact (generated_event_json "speech.never" value),
      `None );
  ]

let property_sse_chunk_partitions_and_line_classes =
  let generated =
    QCheck.make
      ~print:(fun (seeds, (malformed_seed, value)) ->
        Printf.sprintf "{partitions=[%s]; malformed_seed=%d; value=%d}"
          (String.concat "," (List.map string_of_int seeds))
          malformed_seed value)
      QCheck.Gen.
        (pair (list_size (int_range 0 12) int)
           (pair int (int_range (-1_000_000) 1_000_000)))
  in
  QCheck.Test.make
    ~name:
      "oastr-h2 generated SSE partitions cover BOM CR LF CRLF fields multiline empty-data and EOF classes"
    ~count generated (fun (seeds, (malformed_seed, value)) ->
      let class_cases =
        sse_classes value
        @
        [
          ( "generated-malformed",
            "",
            Printf.sprintf "data: malformed-%d\n\n" malformed_seed,
            `Decode );
        ]
      in
      let classes = ref 0 in
      let passed =
        List.for_all
          (fun (name, type_, payload, expected) ->
            incr classes;
            let check partition_class chunks =
              let exit, releases = run_event chunks in
              let valid =
                releases = 1
                &&
                match expected with
                | `Unknown expected_json -> (
                    match exit with
                    | Eta.Exit.Ok
                        (Some
                          (O.Audio.Text_to_speech.Unknown
                            { type_ = actual_type; raw = actual_json })) ->
                        String.equal type_ actual_type
                        && actual_json = expected_json
                    | Eta.Exit.Ok None | Eta.Exit.Error _ -> false)
                | `Decode -> check_decode exit
                | `None -> exit = Eta.Exit.Ok None
              in
              if valid then true
              else
                let expected_json =
                  match expected with
                  | `Unknown json -> A.Json.compact json
                  | `Decode -> "<decode>"
                  | `None -> "<none>"
                in
                let actual_type, actual_json =
                  match exit with
                  | Eta.Exit.Ok
                      (Some
                        (O.Audio.Text_to_speech.Unknown
                          { type_; raw })) ->
                      (type_, A.Json.compact raw)
                  | Eta.Exit.Ok None -> ("<none>", "<none>")
                  | Eta.Exit.Error cause ->
                      ( "<error>",
                        Format.asprintf "%a" (Eta.Cause.pp O.Error.pp) cause )
                in
                QCheck.Test.fail_reportf
                  "class=%s partition=%s partitions=[%s] chunk_lengths=[%s] releases=%d expected_type=%S actual_type=%S expected_json=%s actual_json=%s exit=%a payload=%S"
                  name partition_class
                  (String.concat "," (List.map string_of_int seeds))
                  (String.concat ","
                     (List.map (fun chunk -> string_of_int (Bytes.length chunk))
                        chunks))
                  releases type_ actual_type expected_json actual_json
                  pp_event_exit exit payload
            in
            check "single" [ Bytes.of_string payload ]
            && check "partitioned" (partition seeds payload))
          class_cases
      in
      if !classes <> 8 then
        QCheck.Test.fail_reportf
          "class=accounting expected=8 actual=%d partitions=[%s] malformed_seed=%d"
          !classes
          (String.concat "," (List.map string_of_int seeds))
          malformed_seed;
      passed)

let property_sse_bounds =
  let generated =
    QCheck.make
      ~print:(fun (seeds, limit_seed) ->
        Printf.sprintf "{partitions=[%s]; limit_seed=%d}"
          (String.concat "," (List.map string_of_int seeds))
          limit_seed)
      QCheck.Gen.(pair (list_size (int_range 1 12) int) int)
  in
  QCheck.Test.make
    ~name:
      "oastr-h3 generated hostile chunks enforce framing JSON and pending bounds"
    ~count generated (fun (seeds, limit_seed) ->
      let limit = 1 + abs (limit_seed mod 64) in
      let cases =
        [
          ( "framing",
            "speech SSE unframed bytes",
            limit,
            limit + 16,
            8,
            String.make (limit + 1) 'x',
            'u' );
          ( "json",
            "speech SSE JSON bytes",
            limit + 16,
            limit,
            8,
            "data: " ^ String.make (limit + 1) '1' ^ "\n\n",
            'J' );
          ( "pending-before-decode",
            "speech SSE pending events",
            128,
            64,
            1,
            "data: {\"type\":\"first\"}\n\ndata: decode-must-not-run\n\n",
            'p' );
        ]
      in
      let classes = ref 0 in
      let passed =
        List.for_all
          (fun (name, kind, max_buffer_bytes, max_json_bytes,
                max_pending_events, payload, kind_marker) ->
            incr classes;
            let check chunks =
              let exit, releases =
                run_event ~max_buffer_bytes ~max_json_bytes
                  ~max_pending_events chunks
              in
              let valid =
                releases = 1 && check_limit kind_marker exit
                &&
                match exit with
                | Eta.Exit.Error
                    (Eta.Cause.Fail
                      (O.Error.Limit_exceeded
                        { kind = actual; limit; actual = measured })) ->
                    String.equal actual kind && measured = limit + 1
                | _ -> false
              in
              if not valid then
                QCheck.Test.fail_reportf
                  "class=%s chunk_lengths=[%s] releases=%d exit=%a payload=%S"
                  name
                  (String.concat ","
                     (List.map (fun chunk -> string_of_int (Bytes.length chunk))
                        chunks))
                  releases pp_event_exit exit payload;
              valid
            in
            check [ Bytes.of_string payload ]
            &&
            if String.equal name "pending-before-decode" then true
            else check (partition seeds payload))
          cases
      in
      if !classes <> 3 then
        QCheck.Test.fail_reportf
          "class=accounting expected=3 actual=%d partitions=[%s] limit_seed=%d"
          !classes
          (String.concat "," (List.map string_of_int seeds))
          limit_seed;
      passed)

let utf8_of_scalar value =
  if value <= 0x7f then String.make 1 (Char.chr value)
  else if value <= 0x7ff then
    String.init 2 (function
      | 0 -> Char.chr (0xc0 lor (value lsr 6))
      | _ -> Char.chr (0x80 lor (value land 0x3f)))
  else if value <= 0xffff then
    String.init 3 (function
      | 0 -> Char.chr (0xe0 lor (value lsr 12))
      | 1 -> Char.chr (0x80 lor ((value lsr 6) land 0x3f))
      | _ -> Char.chr (0x80 lor (value land 0x3f)))
  else
    String.init 4 (function
      | 0 -> Char.chr (0xf0 lor (value lsr 18))
      | 1 -> Char.chr (0x80 lor ((value lsr 12) land 0x3f))
      | 2 -> Char.chr (0x80 lor ((value lsr 6) land 0x3f))
      | _ -> Char.chr (0x80 lor (value land 0x3f)))

let repeat value count =
  let buffer = Buffer.create (String.length value * count) in
  for _ = 1 to count do
    Buffer.add_string buffer value
  done;
  Buffer.contents buffer

let property_unicode_input_instruction_boundaries =
  let scalar_gen =
    QCheck.Gen.(
      map
        (fun (ascii, (two, (three_low, (three_high, four)))) ->
          [
            ("ascii", ascii);
            ("two-byte", two);
            ("three-byte-low", three_low);
            ("three-byte-high", three_high);
            ("four-byte", four);
          ])
        (pair (int_range 0x1 0x7f)
           (pair (int_range 0x80 0x7ff)
              (pair (int_range 0x800 0xd7ff)
                 (pair (int_range 0xe000 0xffff)
                    (int_range 0x10000 0x10ffff))))))
  in
  QCheck.Test.make
    ~name:
      "oaerr-huch generated Unicode scalar classes enforce input and instruction 4096 boundaries"
    ~count
      (QCheck.make
         ~print:(fun scalars ->
           scalars
           |> List.map (fun (name, scalar) ->
                  Printf.sprintf "%s=U+%04X" name scalar)
           |> String.concat ",")
         scalar_gen)
    (fun scalars ->
      let classes = ref 0 in
      let scalar_passed =
        List.for_all
          (fun (name, scalar) ->
            incr classes;
            let unit = utf8_of_scalar scalar in
            let exact = repeat unit 4096 in
            let over = exact ^ unit in
            let checks =
              [
                ("input-exact-4096", Result.is_ok (request exact));
                ("input-over-4097", Result.is_error (request over));
                ( "instructions-exact-4096",
                  Result.is_ok (request ~instructions:exact "input") );
                ( "instructions-over-4097",
                  Result.is_error (request ~instructions:over "input") );
              ]
            in
            List.for_all
              (fun (boundary, valid) ->
                if not valid then
                  QCheck.Test.fail_reportf
                    "class=%s scalar=U+%04X boundary=%s" name scalar boundary;
                valid)
              checks)
          scalars
      in
      let malformed_classes =
        [
          ("overlong", "\xc0\xaf");
          ("surrogate", "\xed\xa0\x80");
          ("above-unicode", "\xf4\x90\x80\x80");
        ]
      in
      let malformed_passed =
        List.for_all
          (fun (name, malformed) ->
            incr classes;
            let input_invalid = Result.is_error (request malformed) in
            let instructions_invalid =
              Result.is_error (request ~instructions:malformed "input")
            in
            if not input_invalid then
              QCheck.Test.fail_reportf "class=%s input=%S target=input" name
                malformed;
            if not instructions_invalid then
              QCheck.Test.fail_reportf
                "class=%s input=%S target=instructions" name malformed;
            input_invalid && instructions_invalid)
          malformed_classes
      in
      if !classes <> 8 then
        QCheck.Test.fail_reportf "class=accounting expected=8 actual=%d"
          !classes;
      scalar_passed && malformed_passed)

let run_audio chunks =
  let releases = ref 0 in
  let body =
    H.Body.Stream.of_bytes
      ~release:(fun () -> E.sync (fun () -> incr releases))
      chunks
  in
  let rec consume stream total =
    O.Audio.Text_to_speech.read_audio stream
    |> E.bind (function
         | None -> E.pure total
         | Some chunk -> consume stream (total + Bytes.length chunk))
  in
  let operation =
    O.Audio.Text_to_speech.stream_audio
      (client (H.Response.make ~status:200 ~body ()))
      ~api_key:(A.api_key "key") (require_ok (audio_request ()))
    |> E.bind (fun stream -> consume stream 0)
  in
  let outcome = Eta_test.Run.run operation in
  Eta_test.Run.expect_no_pending_fibers outcome;
  Gc.full_major ();
  (outcome.exit, !releases)

let run_audio_cancel () =
  let releases = ref 0 in
  let body =
    H.Body.Stream.of_reader
      ~release:(fun () -> E.sync (fun () -> incr releases))
      (fun () -> E.never)
  in
  let operation =
    O.Audio.Text_to_speech.stream_audio
      (client (H.Response.make ~status:200 ~body ()))
      ~api_key:(A.api_key "key") (require_ok (audio_request ()))
    |> E.bind (fun stream ->
           E.race
             [
               (O.Audio.Text_to_speech.read_audio stream
               |> E.map (fun _ -> `Read));
               E.pure `Cancel;
             ])
  in
  let outcome = Eta_test.Run.run operation in
  Eta_test.Run.expect_no_pending_fibers outcome;
  Gc.full_major ();
  (outcome.exit, !releases)

let run_audio_close () =
  let releases = ref 0 in
  let body =
    H.Body.Stream.of_bytes
      ~release:(fun () -> E.sync (fun () -> incr releases))
      [ Bytes.of_string "not-read" ]
  in
  let operation =
    O.Audio.Text_to_speech.stream_audio
      (client (H.Response.make ~status:200 ~body ()))
      ~api_key:(A.api_key "key") (require_ok (audio_request ()))
    |> E.bind O.Audio.Text_to_speech.close_audio
  in
  let outcome = Eta_test.Run.run operation in
  Eta_test.Run.expect_no_pending_fibers outcome;
  Gc.full_major ();
  (outcome.exit, !releases)

let pp_audio_exit fmt = function
  | Eta.Exit.Ok total -> Format.fprintf fmt "Ok(%d)" total
  | Eta.Exit.Error cause -> Eta.Cause.pp O.Error.pp fmt cause

let partition_total weights total =
  let rec loop remaining remaining_weight acc = function
    | [] -> List.rev acc
    | [ _ ] -> List.rev (remaining :: acc)
    | weight :: rest ->
        let length = max 1 ((remaining * weight) / remaining_weight) in
        loop (remaining - length) (remaining_weight - weight) (length :: acc)
          rest
  in
  let remaining_weight = List.fold_left ( + ) 0 weights in
  loop total remaining_weight [] weights

let property_raw_audio_has_no_total_cap =
  let generated =
    QCheck.make
      ~print:(fun (total, weights) ->
        Printf.sprintf "{total=%d; weights=[%s]}" total
          (String.concat "," (List.map string_of_int weights)))
      QCheck.Gen.
        (pair
           (int_range
              (O.Audio.Text_to_speech.default_max_buffer_bytes + 1)
              (O.Audio.Text_to_speech.default_max_buffer_bytes + 65536))
           (list_size (int_range 2 16) (int_range 1 1024)))
  in
  QCheck.Test.make
    ~name:
      "oastr-39sn generated raw-audio totals and chunkings have no implicit cap"
    ~count generated (fun (total, weights) ->
      let partitioned = partition_total weights total in
      let classes =
        [
          ("above-default-single", [ total ]);
          ("above-default-partitioned", partitioned);
          ("above-default-empty-chunks", 0 :: partitioned @ [ 0 ]);
        ]
      in
      let class_count = ref 0 in
      let audio_passed =
        List.for_all
           (fun (name, lengths) ->
             incr class_count;
             let chunks = List.map (fun length -> Bytes.make length 'a') lengths in
             let expected = List.fold_left ( + ) 0 lengths in
             match run_audio chunks with
             | Eta.Exit.Ok actual, 1 ->
                 if actual <> expected then
                   QCheck.Test.fail_reportf
                     "class=%s total=%d lengths=[%s] expected=%d actual=%d releases=1"
                     name total
                     (String.concat "," (List.map string_of_int lengths))
                     expected actual;
                 actual = expected
             | exit, releases ->
                 QCheck.Test.fail_reportf
                   "class=%s total=%d lengths=[%s] releases=%d exit=%a" name
                   total
                   (String.concat "," (List.map string_of_int lengths))
                   releases pp_audio_exit exit)
           classes
      in
      let cancellation_passed =
        incr class_count;
        match run_audio_cancel () with
        | Eta.Exit.Ok `Cancel, 1 -> true
        | exit, releases ->
            QCheck.Test.fail_reportf
              "class=cancel total=%d releases=%d outcome=%s" total releases
              (match exit with
              | Eta.Exit.Ok `Read -> "Ok(Read)"
              | Eta.Exit.Ok `Cancel -> "Ok(Cancel)"
              | Eta.Exit.Error cause ->
                  Format.asprintf "%a" (Eta.Cause.pp O.Error.pp) cause)
      in
      let close_passed =
        incr class_count;
        match run_audio_close () with
        | Eta.Exit.Ok (), 1 -> true
        | exit, releases ->
            QCheck.Test.fail_reportf
              "class=explicit-close total=%d releases=%d outcome=%s" total
              releases
              (match exit with
              | Eta.Exit.Ok () -> "Ok"
              | Eta.Exit.Error cause ->
                  Format.asprintf "%a" (Eta.Cause.pp O.Error.pp) cause)
      in
      if !class_count <> 5 then
        QCheck.Test.fail_reportf
          "class=accounting expected=5 actual=%d total=%d" !class_count total;
      audio_passed && cancellation_passed && close_passed)

let property_collector_checked_arithmetic =
  let values =
    QCheck.make
      ~print:(fun (total, chunk_length, slack) ->
        Printf.sprintf "{total=%d; chunk_length=%d; slack=%d}" total
          chunk_length slack)
      QCheck.Gen.
        (triple (int_range 0 1_000_000) (int_range 0 1_000_000)
           (int_range 0 1_000_000))
  in
  QCheck.Test.make
    ~name:
      "oatts-m8 generated collector arithmetic checks before addition and saturates unrepresentable actual"
    ~count values (fun (total, chunk_length, slack) ->
      let max_bytes = total + slack in
      let generated =
        Collector_math.checked_total ~max_bytes ~total ~chunk_length
      in
      let expected =
        if chunk_length > slack then Error (total + chunk_length)
        else Ok (total + chunk_length)
      in
      let classes =
        [
          ("generated", max_bytes, total, chunk_length, generated, expected);
          ( "exact-max-int",
            max_int,
            max_int - 1,
            1,
            Collector_math.checked_total ~max_bytes:max_int
              ~total:(max_int - 1) ~chunk_length:1,
            Ok max_int );
          ( "one-over-limit",
            max_int - 1,
            max_int - 2,
            2,
            Collector_math.checked_total ~max_bytes:(max_int - 1)
              ~total:(max_int - 2) ~chunk_length:2,
            Error max_int );
          ( "saturated-unrepresentable",
            max_int,
            max_int,
            1,
            Collector_math.checked_total ~max_bytes:max_int ~total:max_int
              ~chunk_length:1,
            Error max_int );
        ]
      in
      let classes_seen = ref 0 in
      let passed =
        List.for_all
          (fun (name, case_max, case_total, case_chunk, actual, expected) ->
            incr classes_seen;
            if actual <> expected then
              QCheck.Test.fail_reportf
                "class=%s max_bytes=%d total=%d chunk_length=%d actual=%s expected=%s"
                name case_max case_total case_chunk
                (match actual with
                | Ok value -> Printf.sprintf "Ok(%d)" value
                | Error value -> Printf.sprintf "Error(%d)" value)
                (match expected with
                | Ok value -> Printf.sprintf "Ok(%d)" value
                | Error value -> Printf.sprintf "Error(%d)" value);
            actual = expected)
          classes
      in
      if !classes_seen <> 4 then
        QCheck.Test.fail_reportf "class=accounting expected=4 actual=%d"
          !classes_seen;
      passed)

let () =
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:qcheck_seed
      [
        property_sse_chunk_partitions_and_line_classes;
        property_sse_bounds;
        property_unicode_input_instruction_boundaries;
        property_raw_audio_has_no_total_cap;
        property_collector_checked_arithmetic;
      ]
  in
  exit code
