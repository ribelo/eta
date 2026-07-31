module Response_idle_timeout = Eta_http.Request.Response_idle_timeout
module E = Eta.Effect
module H = Eta_http
module M = H.Multipart

let qcheck_seed = Random.State.make [| 0xE22; 0x4854_5450 |]
let count = 100

let nonpositive =
  QCheck.map
    (fun value -> if value = Int.min_int then value else -abs value)
    QCheck.int

let positive =
  QCheck.map
    (fun value -> if value = Int.max_int then value else value + 1)
    QCheck.int_pos

let property_response_idle_timeout_domain =
  QCheck.Test.make
    ~name:
      "response idle timeout rejects generated nonpositive milliseconds and round-trips generated positive milliseconds"
    ~count QCheck.(pair nonpositive positive)
    (fun (invalid, milliseconds) ->
      let rejects_invalid =
        match Response_idle_timeout.of_ms invalid with
        | _ -> false
        | exception Invalid_argument _ -> true
      in
      let round_trip =
        Response_idle_timeout.of_ms milliseconds
        |> Response_idle_timeout.to_ms
        |> Option.equal Int.equal (Some milliseconds)
      in
      rejects_invalid && round_trip)

let bytes_of_ints values =
  values
  |> List.map (fun value -> if value = 13 then 14 else value)
  |> List.map Char.chr |> List.to_seq |> Bytes.of_seq

let pp_ints values =
  values
  |> List.map (fun value -> Printf.sprintf "%02x" value)
  |> String.concat ""

let generated_bytes =
  QCheck.make ~print:pp_ints
    QCheck.Gen.(list_size (int_range 0 96) (int_range 0 255))

let pp_seeds values =
  values |> List.map string_of_int |> String.concat "," |> Printf.sprintf "[%s]"

let generated_seeds =
  QCheck.make ~print:pp_seeds
    QCheck.Gen.(list_size (int_range 1 12) (int_range 0 32))

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

let contains bytes needle =
  let length = Bytes.length bytes in
  let needle_length = String.length needle in
  let rec equal_at offset index =
    index = needle_length
    ||
    (Bytes.get bytes (offset + index) = String.get needle index
    && equal_at offset (index + 1))
  in
  let rec loop offset =
    offset + needle_length <= length
    && (equal_at offset 0 || loop (offset + 1))
  in
  needle_length = 0 || loop 0

let partition seeds bytes =
  let length = Bytes.length bytes in
  let seeds = if seeds = [] then [ 0 ] else seeds in
  let seeds = Array.of_list seeds in
  let rec loop offset index chunks =
    if offset = length then List.rev chunks
    else
      let size = 1 + (seeds.(index mod Array.length seeds) mod 17) in
      let size = min size (length - offset) in
      loop (offset + size) (index + 1)
        (Bytes.sub bytes offset size :: chunks)
  in
  loop 0 0 []

let source_of_chunks opened chunks =
  {
    M.length = Some (Int64.of_int (Bytes.length (concat chunks)));
    replayability = M.Replayable;
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
      filename = "generated.bin";
      content_type = "application/octet-stream";
      data = M.Pull source;
    }

let stream_of_body = function
  | H.Request.Stream stream -> stream
  | H.Request.One_shot_stream { stream; _ } -> stream
  | H.Request.Rewindable_stream { make; _ } -> make ()
  | H.Request.Empty | H.Request.Fixed _ -> assert false

let run program =
  let outcome = Eta_test.Run.run program in
  if outcome.pending_fibers <> Some [] then
    QCheck.Test.fail_reportf "pending_fibers must be an available empty census";
  outcome.exit

let expected_body boundary payload =
  concat
    [
      Bytes.of_string
        ("--" ^ boundary
       ^ "\r\nContent-Disposition: form-data; name=\"file\"; \
          filename=\"generated.bin\"\r\nContent-Type: \
          application/octet-stream\r\n\r\n");
      payload;
      Bytes.of_string "\r\n";
      Bytes.of_string ("--" ^ boundary ^ "--\r\n");
    ]

(* Observation boundary: complete request-body bytes, exact length, open count,
   fresh boundary, and available empty fiber census. Generated class: arbitrary
   0..96-byte payloads without CR, under single, bytewise, seeded, and
   empty-interspersed source partitions. *)
let property_multipart_noncollision_partitions =
  QCheck.Test.make
    ~name:
      "multipart generated noncollision partitions preserve bytes order exact length laziness replay and empty census"
    ~count QCheck.(pair generated_bytes generated_seeds)
    (fun (values, seeds) ->
      let payload = bytes_of_ints values in
      let bytewise =
        List.init (Bytes.length payload) (fun index -> Bytes.sub payload index 1)
      in
      let seeded = partition seeds payload in
      let classes =
        [
          ("single", [ payload ]);
          ("bytewise", bytewise);
          ("seeded", seeded);
          ( "empty-interspersed",
            List.concat_map (fun chunk -> [ Bytes.empty; chunk ]) seeded
            @ [ Bytes.empty ] );
        ]
      in
      let class_count = ref 0 in
      let passed =
        List.for_all
          (fun (class_, chunks) ->
            incr class_count;
            let opened = ref 0 in
            let multipart =
              match M.make [ stream_part (source_of_chunks opened chunks) ] with
              | Ok multipart -> multipart
              | Error error ->
                  QCheck.Test.fail_reportf
                    "class=%s payload=%s seeds=%s construction=%s" class_
                    (pp_ints values) (pp_seeds seeds)
                    (M.error_message error)
            in
            if !opened <> 0 then
              QCheck.Test.fail_reportf
                "class=%s payload=%s seeds=%s opened-before-read=%d" class_
                (pp_ints values) (pp_seeds seeds) !opened;
            let second =
              match M.make [ stream_part (source_of_chunks (ref 0) chunks) ] with
              | Ok multipart -> multipart
              | Error _ -> assert false
            in
            let fresh = not (String.equal multipart.boundary second.boundary) in
            let expected = expected_body multipart.boundary payload in
            let first =
              run
                (H.Body.Stream.read_all ~max_bytes:4096
                   (stream_of_body multipart.body))
            in
            let second_attempt =
              run
                (H.Body.Stream.read_all ~max_bytes:4096
                   (stream_of_body multipart.body))
            in
            let valid =
              match first, second_attempt with
              | Eta.Exit.Ok first, Eta.Exit.Ok second_attempt ->
                  Bytes.equal first expected && Bytes.equal second_attempt expected
                  && multipart.content_length
                     = Some (Int64.of_int (Bytes.length expected))
                  && !opened = 2 && fresh
                  && String.starts_with ~prefix:"eta-http-"
                       multipart.boundary
              | Eta.Exit.Ok _, Eta.Exit.Error _
              | Eta.Exit.Error _, Eta.Exit.Ok _
              | Eta.Exit.Error _, Eta.Exit.Error _ ->
                  false
            in
            if not valid then
              QCheck.Test.fail_reportf
                "class=%s payload=%s seeds=%s opened=%d boundary=%S length=%s"
                class_ (pp_ints values) (pp_seeds seeds) !opened
                multipart.boundary
                (match multipart.content_length with
                | None -> "unknown"
                | Some length -> Int64.to_string length);
            valid)
          classes
      in
      if !class_count <> 4 then
        QCheck.Test.fail_reportf "class=accounting expected=4 actual=%d"
          !class_count;
      passed)

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

(* Observation boundary: emitted request-body bytes and typed exit, plus an
   available empty fiber census. Generated class: arbitrary CR-free prefix and
   suffix bytes, with the exact MIME delimiter inside the source and the
   header/source boundary token each split at every offset. *)
let property_multipart_collision_partitions =
  QCheck.Test.make
    ~name:
      "multipart generated delimiter collisions split at every offset fail before full delimiter and leave empty census"
    ~count QCheck.(pair generated_bytes generated_bytes)
    (fun (prefix_values, suffix_values) ->
      let prefix = bytes_of_ints prefix_values in
      let suffix = bytes_of_ints suffix_values in
      let boundary = ref "" in
      let split = ref 0 in
      let at_source_start = ref false in
      let source =
        {
          M.length = None;
          replayability = M.Replayable;
          open_reader =
            (fun () ->
              let delimiter =
                Bytes.of_string
                  ((if !at_source_start then "--" else "\r\n--") ^ !boundary)
              in
              let payload =
                if !at_source_start then concat [ delimiter; suffix ]
                else concat [ prefix; delimiter; suffix ]
              in
              let cut =
                (if !at_source_start then 0 else Bytes.length prefix) + !split
              in
              let chunks =
                ref
                  [
                    Bytes.sub payload 0 cut;
                    Bytes.sub payload cut (Bytes.length payload - cut);
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
      let multipart =
        match M.make [ stream_part source ] with
        | Ok multipart -> multipart
        | Error error ->
            QCheck.Test.fail_reportf "construction=%s"
              (M.error_message error)
      in
      boundary := multipart.boundary;
      let delimiter = "\r\n--" ^ multipart.boundary in
      let source_start = "--" ^ multipart.boundary in
      let classes = ref 0 in
      let valid = ref true in
      let check class_ offset =
        incr classes;
        split := offset;
        match emitted_until_failure (stream_of_body multipart.body) with
        | Eta.Exit.Ok (`Failed (emitted, error)) ->
            let collision =
              match error.H.Error.kind with
              | H.Error.Decode_error { codec = "multipart-boundary"; _ } -> true
              | _ -> false
            in
            let no_delimiter = not (contains emitted delimiter) in
            if not (collision && no_delimiter) then (
              valid := false;
              QCheck.Test.fail_reportf
                "class=%s split=%d prefix=%s suffix=%s emitted=%S error=%s"
                class_ offset
                (pp_ints prefix_values) (pp_ints suffix_values)
                (Bytes.to_string emitted)
                (H.Error.to_string error))
        | Eta.Exit.Ok (`Ended emitted) ->
            valid := false;
            QCheck.Test.fail_reportf
              "class=%s split=%d prefix=%s suffix=%s accepted emitted=%S"
              class_ offset
              (pp_ints prefix_values) (pp_ints suffix_values)
              (Bytes.to_string emitted)
        | Eta.Exit.Error cause ->
            valid := false;
            QCheck.Test.fail_reportf
              "class=%s split=%d prefix=%s suffix=%s observer=%a" class_
              offset
              (pp_ints prefix_values) (pp_ints suffix_values)
              (Eta.Cause.pp H.Error.pp)
              cause
      in
      at_source_start := false;
      for offset = 0 to String.length delimiter do
        check "in-source" offset
      done;
      at_source_start := true;
      for offset = 0 to String.length source_start do
        check "header-source" offset
      done;
      let expected_classes =
        String.length delimiter + 1 + String.length source_start + 1
      in
      if !classes <> expected_classes then
        QCheck.Test.fail_reportf "class=accounting expected=%d actual=%d"
          expected_classes !classes;
      !valid)

let length_source ~declared chunks =
  {
    M.length = Some (Int64.of_int declared);
    replayability = M.Replayable;
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

let source_length_result body =
  match
    run
      (H.Body.Stream.read_all ~max_bytes:4096 (stream_of_body body))
  with
  | Eta.Exit.Ok _ -> `Ok
  | Eta.Exit.Error
      (Eta.Cause.Fail
        {
          H.Error.kind =
            H.Error.Decode_error
              { codec = "multipart-source-length"; message };
          _;
        }) ->
      `Length message
  | Eta.Exit.Error cause ->
      QCheck.Test.fail_reportf "unexpected source length cause=%a"
        (Eta.Cause.pp H.Error.pp)
        cause

(* Observation boundary: complete body exit, stable mismatch codec/message, and
   available empty fiber census. Generated class: arbitrary CR-free payloads
   under seeded partitions, exact/undershoot/overshoot including zero-length
   witnesses, and two-source exact or mismatching bodies. *)
let property_multipart_declared_lengths =
  QCheck.Test.make
    ~name:
      "multipart generated declared source lengths enforce undershoot exact overshoot zero and multiple sources with empty census"
    ~count QCheck.(pair generated_bytes generated_seeds)
    (fun (values, seeds) ->
      let payload = bytes_of_ints values in
      let payload_length = Bytes.length payload in
      let chunks = partition seeds payload in
      let over_payload = concat [ payload; Bytes.of_string "x" ] in
      let over_chunks = partition seeds over_payload in
      let make sources =
        match M.make (List.map (fun source -> stream_part source) sources) with
        | Ok multipart -> multipart
        | Error error ->
            QCheck.Test.fail_reportf "payload=%s seeds=%s construction=%s"
              (pp_ints values) (pp_seeds seeds) (M.error_message error)
      in
      let classes =
        [
          ( "exact",
            make [ length_source ~declared:payload_length chunks ],
            `Ok );
          ( "undershoot",
            make [ length_source ~declared:(payload_length + 1) chunks ],
            `Length "source ended before its declared length" );
          ( "overshoot",
            make [ length_source ~declared:payload_length over_chunks ],
            `Length "source chunk exceeds its declared length" );
          ("exact-zero", make [ length_source ~declared:0 [] ], `Ok);
          ( "undershoot-zero",
            make [ length_source ~declared:1 [] ],
            `Length "source ended before its declared length" );
          ( "overshoot-zero",
            make
              [
                length_source ~declared:0
                  [ Bytes.of_string "x" ];
              ],
            `Length "source chunk exceeds its declared length" );
          ( "multiple-exact",
            make
              [
                length_source ~declared:payload_length chunks;
                length_source ~declared:0 [];
              ],
            `Ok );
          ( "multiple-second-undershoot",
            make
              [
                length_source ~declared:payload_length chunks;
                length_source ~declared:1 [];
              ],
            `Length "source ended before its declared length" );
          ( "multiple-first-overshoot",
            make
              [
                length_source ~declared:payload_length over_chunks;
                length_source ~declared:0 [];
              ],
            `Length "source chunk exceeds its declared length" );
        ]
      in
      let class_count = ref 0 in
      let passed =
        List.for_all
          (fun (class_, (multipart : M.t), expected) ->
            incr class_count;
            let actual = source_length_result multipart.body in
            let valid = actual = expected in
            if not valid then
              QCheck.Test.fail_reportf
                "class=%s payload=%s seeds=%s expected=%s actual=%s" class_
                (pp_ints values) (pp_seeds seeds)
                (match expected with `Ok -> "ok" | `Length message -> message)
                (match actual with `Ok -> "ok" | `Length message -> message);
            valid)
          classes
      in
      if !class_count <> 9 then
        QCheck.Test.fail_reportf "class=accounting expected=9 actual=%d"
          !class_count;
      passed)

let () =
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:qcheck_seed
      [
        property_response_idle_timeout_domain;
        property_multipart_noncollision_partitions;
        property_multipart_collision_partitions;
        property_multipart_declared_lengths;
      ]
  in
  exit code
