module R = Eta_ai_openai.Audio.Realtime

let qcheck_seed = Random.State.make [| 0x0EA1_7; 0x0C5E_7 |]
let count = 100

(* Event type identifiers are dotted identifier chains. *)
let event_type_gen =
  QCheck.Gen.(
    let segment = string_size ~gen:(char_range 'a' 'z') (int_range 1 6) in
    map2
      (fun segments marker ->
        ( String.concat "."
            (List.filter (fun part -> String.length part > 0) segments),
          marker ))
      (list_size (int_range 1 4) segment)
      (int_range 0 1000000))

let with_type type_ marker =
  Printf.sprintf {|{"type":"%s","marker":%d}|} type_ marker

let property_unknown_preserved_all_protocols =
  QCheck.Test.make
    ~name:
      "oaerr-koau generated unknown event types decode to Unknown with complete JSON in all three protocols"
    ~count
      (QCheck.make
         ~print:(fun (type_, marker) ->
           Printf.sprintf "(%S, %d)" type_ marker)
         event_type_gen)
      (fun (type_, marker) ->
      (* Exclude types that collide with documented events, so the property
         always exercises the Unknown branch. *)
      let documented_prefix =
        [ "error"; "session."; "conversation."; "response.";
          "input_audio_buffer."; "output_audio_buffer."; "rate_limits." ]
      in
      if
        String.equal type_ "" || String.equal type_ "error"
        || List.exists
             (fun prefix -> String.starts_with ~prefix type_)
             (List.tl documented_prefix)
      then true
      else
        let raw = with_type type_ marker in
        let marker_preserved json =
          Eta_ai.Json.int_member "marker" json = Some marker
        in
        (match R.Conversation.decode_server_event raw with
         | Ok (R.Conversation.Unknown { type_ = actual; raw = json }) ->
             String.equal actual type_ && marker_preserved json
         | _ -> false)
        &&
        (match R.Transcription.decode_server_event raw with
         | Ok (R.Transcription.Unknown { type_ = actual; raw = json }) ->
             String.equal actual type_ && marker_preserved json
         | _ -> false)
        &&
        match R.Translation.decode_server_event raw with
        | Ok (R.Translation.Unknown { type_ = actual; raw = json }) ->
            String.equal actual type_ && marker_preserved json
        | _ -> false)

(* A generated malformed-input class: objects missing a string [type], objects
   with a generated non-string [type], generated JSON scalars, and generated
   non-JSON strings. *)
let json_scalar_gen =
  QCheck.Gen.(
    oneof
      [
        map string_of_int (int_range 0 1000000);
        map (function true -> "true" | false -> "false") bool;
        map (fun value -> Printf.sprintf "\"%s\"" value)
          (string_size ~gen:(char_range 'a' 'z') (int_range 0 8));
        return "null";
      ])

let malformed_gen =
  QCheck.Gen.(
    let missing_type =
      map2
        (fun key value ->
          Printf.sprintf {|{"%s":%s}|}
            (if String.equal key "type" then "kind" else key)
            value)
        (string_size ~gen:(char_range 'a' 'z') (int_range 0 6))
        json_scalar_gen
    in
    let non_string_type =
      map
        (fun value -> Printf.sprintf {|{"type":%s}|} value)
        (oneof
           [
             map string_of_int (int_range 0 1000000);
             return "[1,2]";
             return "{\"code\":\"c\"}";
             return "null";
           ])
    in
    let non_json =
      map
        (fun prefix -> prefix ^ "{not-json")
        (string_size ~gen:(char_range 'a' 'z') (int_range 0 6))
    in
    oneof [ missing_type; non_string_type; json_scalar_gen; non_json ])

let property_malformed_rejected_all_protocols =
  QCheck.Test.make
    ~name:
      "oaerr-noio generated malformed frames are codec failures in all three protocols"
    ~count (QCheck.make ~print:(fun raw -> Printf.sprintf "%S" raw) malformed_gen)
      (fun raw ->
      let conversation =
        match R.Conversation.decode_server_event raw with
        | Error (R.Conversation.Decode _) -> true
        | _ -> false
      in
      let transcription =
        match R.Transcription.decode_server_event raw with
        | Error (R.Transcription.Decode _) -> true
        | _ -> false
      in
      let translation =
        match R.Translation.decode_server_event raw with
        | Error (R.Translation.Decode _) -> true
        | _ -> false
      in
      conversation && transcription && translation)

let turn_detection_batch_gen =
  let classes =
    List.concat_map
      (fun field ->
        List.map
          (fun representation -> (field, representation))
          [ `Int_repr; `Float_repr; `Intlit_repr ])
      [ "threshold"; "idle_timeout_ms"; "prefix_padding_ms";
        "silence_duration_ms" ]
  in
  QCheck.Gen.(
    map
      (fun values ->
        List.map2
          (fun (field, representation) value ->
            let json, numeric, label =
              match representation with
              | `Int_repr -> (`Int value, float_of_int value, "int")
              | `Float_repr ->
                  (`Float (float_of_int value /. 2.0),
                   float_of_int value /. 2.0, "float")
              | `Intlit_repr ->
                  (`Intlit (string_of_int value), float_of_int value, "intlit")
            in
            let expected =
              match field with
              | "threshold" -> numeric >= 0.0 && numeric <= 1.0
              | _ -> numeric >= 0.0
            in
            (field, label, json, expected))
          classes values)
      (list_size (return (List.length classes)) (int_range (-4) 5)))

let print_turn_detection_case (field, label, json, expected) =
  Printf.sprintf "(%s, %s, %s, expected=%b)" field label
    (Eta_ai.Json.to_string json) expected

let property_turn_detection_numeric_ranges =
  QCheck.Test.make
    ~name:
      "oaerr-huch generated turn detection numeric ranges reject out-of-range values in both session constructors"
    ~count
    (QCheck.make
       ~print:(fun cases ->
         String.concat "; " (List.map print_turn_detection_case cases))
       turn_detection_batch_gen)
    (fun cases ->
      let classes =
        cases
        |> List.map (fun (field, representation, _, _) ->
               (field, representation))
        |> List.sort_uniq compare
      in
      if List.length cases <> 12 || List.length classes <> 12 then
        QCheck.Test.fail_reportf
          "generated class coverage incomplete: cases=%d distinct=%d"
          (List.length cases) (List.length classes);
      List.iter
        (fun ((field, _label, json, expected) as case) ->
          let turn_detection =
            `Assoc [ ("type", `String "server_vad"); (field, json) ]
          in
          let conversation =
            R.Conversation.session ~model:"gpt-realtime-2"
              ~turn_detection:(R.Conversation.Turn_detection turn_detection) ()
            |> Result.is_ok
          in
          let transcription =
            R.Transcription.session
              ~input_audio_format:R.Transcription.Pcm16_24khz
              ~model:"gpt-live-transcribe" ~turn_detection ()
            |> Result.is_ok
          in
          if conversation <> expected || transcription <> expected then
            QCheck.Test.fail_reportf
              "counterexample=%s conversation=%b transcription=%b"
              (print_turn_detection_case case) conversation transcription)
        cases;
      true)

let json_integer_lexical_batch_gen =
  QCheck.Gen.(
    let digit_tail size =
      string_size ~gen:(char_range '0' '9') size
    in
    let* first = char_range '1' '9' in
    let* tail = digit_tail (int_range 0 20) in
    let* huge_tail = digit_tail (int_range 99 499) in
    let* alpha =
      string_size ~gen:(char_range 'a' 'z') (int_range 1 20)
    in
    let positive = String.make 1 first ^ tail in
    let huge_positive = String.make 1 first ^ huge_tail in
    return
      [ ("zero", "0", true); ("negative-zero", "-0", true);
        ("positive", positive, true);
        ("huge-positive", huge_positive, true);
        ("negative-nonzero", "-" ^ positive, false);
        ("plus", "+" ^ positive, false);
        ("leading-zero", "0" ^ positive, false);
        ("hex", "0x" ^ positive, false);
        ("underscore", positive ^ "_0", false);
        ("trailing-dot", positive ^ ".", false);
        ("decimal", positive ^ ".0", false);
        ("exponent", positive ^ "e2", false);
        ("alphabetic", alpha, false); ("empty", "", false);
        ("sign-only", "-", false) ])

let property_json_integer_lexical_classes =
  QCheck.Test.make
    ~name:
      "oaerr-huch generated JSON integer lexical classes and huge values are validated in both session constructors"
    ~count
    (QCheck.make
       ~print:(fun cases ->
         cases
         |> List.map (fun (class_, literal, expected) ->
                Printf.sprintf "(%s,%S,expected=%b)" class_ literal expected)
         |> String.concat "; ")
       json_integer_lexical_batch_gen)
    (fun cases ->
      let classes =
        cases |> List.map (fun (class_, _, _) -> class_)
        |> List.sort_uniq String.compare
      in
      if List.length cases <> 15 || List.length classes <> 15 then
        QCheck.Test.fail_reportf
          "generated lexical coverage incomplete: cases=%d distinct=%d"
          (List.length cases) (List.length classes);
      List.iter
        (fun (class_, literal, expected) ->
          let turn_detection =
            `Assoc
              [ ("type", `String "server_vad");
                ("prefix_padding_ms", `Intlit literal) ]
          in
          let conversation =
            R.Conversation.session ~model:"gpt-realtime-2"
              ~turn_detection:(R.Conversation.Turn_detection turn_detection) ()
            |> Result.is_ok
          in
          let transcription =
            R.Transcription.session
              ~input_audio_format:R.Transcription.Pcm16_24khz
              ~model:"gpt-live-transcribe" ~turn_detection ()
            |> Result.is_ok
          in
          if conversation <> expected || transcription <> expected then
            QCheck.Test.fail_reportf
              "class=%s literal=%S expected=%b conversation=%b transcription=%b"
              class_ literal expected conversation transcription)
        cases;
      true)

let binary_payload_gen =
  QCheck.Gen.(
    map Bytes.of_string
      (string_size ~gen:(map Char.chr (int_range 0 255)) (int_range 0 16)))

let property_binary_frames_rejected_all_protocols =
  QCheck.Test.make
    ~name:
      "oaerr-noio generated binary frames are codec failures in all three sibling codecs"
    ~count
    (QCheck.make
       ~print:(fun bytes -> Printf.sprintf "%d bytes" (Bytes.length bytes))
       binary_payload_gen)
    (fun payload ->
      let message = Eta_ai.Realtime.Binary payload in
      let conversation =
        match R.Conversation.Codec.decode_server_event message with
        | Error _ -> true
        | Ok _ -> false
      in
      let transcription =
        match R.Transcription.Codec.decode_server_event message with
        | Error _ -> true
        | Ok _ -> false
      in
      let translation =
        match R.Translation.Codec.decode_server_event message with
        | Error _ -> true
        | Ok _ -> false
      in
      conversation && transcription && translation)

let () =
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:qcheck_seed
      [
        property_unknown_preserved_all_protocols;
        property_malformed_rejected_all_protocols;
        property_turn_detection_numeric_ranges;
        property_json_integer_lexical_classes;
        property_binary_frames_rejected_all_protocols;
      ]
  in
  exit code
