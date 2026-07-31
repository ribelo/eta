module A = Eta_ai
module O = Eta_ai_openai
module C = Eta_ai_openai_codec
module J = A.Json
module E = Eta.Effect
module H = Eta_http

let qcheck_seed = Random.State.make [| 0x0A; 0xC4A7; 0xA0D10 |]

let common ?(stream = false) prompt : A.chat_request =
  {
    model = "gpt-audio-1.5";
    prompt;
    tools = [];
    temperature = None;
    reasoning = None;
    max_output_tokens = None;
    replay_items = [];
    stream;
  }

let bytes_gen =
  QCheck.Gen.map
    (fun values ->
      let bytes = Bytes.create (List.length values) in
      List.iteri (fun index value -> Bytes.set_uint8 bytes index value) values;
      bytes)
    QCheck.Gen.
      (list_size
         (oneof_weighted [ (8, 0 -- 1024); (2, 1025 -- 4096) ])
         (0 -- 255))

let audio_response data =
  J.object_
    [
      ("id", Some (J.string "chatcmpl_audio"));
      ("object", Some (J.string "chat.completion"));
      ("created", Some (J.int 17));
      ("model", Some (J.string "gpt-audio-1.5"));
      ( "choices",
        Some
          (J.array
             [
               J.object_
                 [
                   ("index", Some (J.int 0));
                   ("finish_reason", Some (J.string "stop"));
                   ("logprobs", Some `Null);
                   ( "message",
                     Some
                       (J.object_
                          [
                            ("role", Some (J.string "assistant"));
                            ("content", Some (J.string "visible text"));
                            ("refusal", Some `Null);
                            ( "annotations",
                              Some
                                (J.array
                                   [
                                     J.object_
                                       [
                                         ("type", Some (J.string "url_citation"));
                                         ("unknown_annotation", Some (J.int 11));
                                       ];
                                   ]) );
                            ( "tool_calls",
                              Some
                                (J.array
                                   [
                                     J.object_
                                       [
                                         ("id", Some (J.string "call_1"));
                                         ("type", Some (J.string "function"));
                                         ( "function",
                                           Some
                                             (J.object_
                                                [
                                                  ( "name",
                                                    Some (J.string "weather") );
                                                  ( "arguments",
                                                    Some (J.string "{}") );
                                                  ( "unknown_function",
                                                    Some (J.int 9) );
                                                ]) );
                                         ("unknown_tool", Some (J.int 10));
                                       ];
                                   ]) );
                            ( "audio",
                              Some
                                (J.object_
                                   [
                                     ("id", Some (J.string "audio_1"));
                                     ("expires_at", Some (J.int 99));
                                     ("data", Some (J.string data));
                                     ("transcript", Some (J.string "spoken text"));
                                     ("unknown_audio", Some (J.bool true));
                                   ]) );
                            ("unknown_message", Some (J.int 2));
                          ]) );
                   ("unknown_choice", Some (J.string "choice fact"));
                 ];
             ]) );
      ( "usage",
        Some
          (J.object_
             [
               ("prompt_tokens", Some (J.int 10));
               ("completion_tokens", Some (J.int 12));
               ("total_tokens", Some (J.int 22));
               ( "prompt_tokens_details",
                 Some
                   (J.object_
                      [
                        ("audio_tokens", Some (J.int 3));
                        ("cached_tokens", Some (J.int 4));
                        ("unknown_prompt", Some (J.int 5));
                      ]) );
               ( "completion_tokens_details",
                 Some
                   (J.object_
                      [
                        ("accepted_prediction_tokens", Some (J.int 1));
                        ("audio_tokens", Some (J.int 6));
                        ("reasoning_tokens", Some (J.int 2));
                        ("rejected_prediction_tokens", Some (J.int 3));
                        ("unknown_completion", Some (J.int 7));
                      ]) );
               ("unknown_usage", Some (J.int 8));
             ]) );
      ("unknown_envelope", Some (J.string "preserved"));
    ]

let property_base64_round_trip =
  QCheck.Test.make
    ~name:
      "oachat-j7yj generated canonical padded base64 decodes without exceptions and preserves exact bytes"
    ~count:300 (QCheck.make ~print:Bytes.to_string bytes_gen)
    (fun bytes ->
      let encoded = Base64.encode_string (Bytes.to_string bytes) in
      let raw = J.to_string (audio_response encoded) in
      match O.Chat.decode raw with
      | Error _ -> false
      | Ok response -> (
          match response.choices with
          | [ { message = { audio = Some audio; _ }; _ } ] -> (
              match O.Chat.audio_bytes audio with
              | Ok actual ->
                  String.equal audio.data encoded && Bytes.equal actual bytes
              | Error _ -> false)
          | _ -> false))

let property_input_wire_fidelity =
  QCheck.Test.make
    ~name:
      "oachat-xn7a generated bytes and preserved base64 Chat inputs encode exact documented wire data"
    ~count:200 (QCheck.make ~print:Bytes.to_string bytes_gen)
    (fun bytes ->
      let encoded = Base64.encode_string (Bytes.to_string bytes) in
      let encode data =
        let content =
          A.Audio { data; format = A.Wav; transcript = Some "not sent" }
        in
        match
          Result.bind
            (O.Chat.request ~common:(common [ A.User [ content ] ]) ())
            O.Chat.encode
        with
        | Error _ -> None
        | Ok raw -> (
            match J.parse raw with
            | Error _ -> None
            | Ok json -> (
                match J.array_member "messages" json with
                | Some [ message ] -> (
                    match J.array_member "content" message with
                    | Some [ part ] ->
                        Option.bind (J.object_member "input_audio" part)
                          (J.string_member "data")
                    | _ -> None)
                | _ -> None))
      in
      encode (A.Bytes bytes) = Some encoded
      && encode (A.Base64 encoded) = Some encoded)

let response_request input : A.tool A.Responses.request =
  {
    model = "gpt-4o";
    input;
    instructions = None;
    previous_response_id = None;
    store = None;
    include_ = [];
    tools = [];
    tool_choice = None;
    parallel_tool_calls = None;
    max_turns = None;
    max_output_tokens = None;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    text = None;
    reasoning = None;
    reasoning_effort = None;
    service_tier = None;
    user = None;
    prompt_cache_key = None;
    replay_items = [];
    stream = false;
  }

let responses_class_counts = Array.make 16 0

let property_responses_rejects_every_audio_position =
  QCheck.Test.make
    ~name:
      "oachat-1jii generated 12 representable role-position and four System-then-User Responses classes cover every public standard path with zero callbacks and empty census"
    ~count:5 (QCheck.make ~print:Bytes.to_string bytes_gen)
    (fun bytes ->
      let encoded = Base64.encode_string (Bytes.to_string bytes) in
      let audio =
        A.Audio
          { data = A.Base64 encoded; format = A.Wav; transcript = None }
      in
      let rec insert index = function
        | [] -> [ audio ]
        | values when index <= 0 -> audio :: values
        | value :: rest -> value :: insert (index - 1) rest
      in
      let unsupported_ai = function
        | Error (A.Unsupported _) -> true
        | Ok _ | Error _ -> false
      in
      let unsupported_codec = function
        | Error (C.Unsupported _) -> true
        | Ok _ | Error _ -> false
      in
      let unsupported_openai = function
        | Error (O.Error.Unsupported _) -> true
        | Ok _ | Error _ -> false
      in
      let effect_unsupported registrations active program =
        match
          Eta_test_backend_eio.Backend.run_counting_forks ~registrations ~active
            program
        with
        | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Unsupported _)) ->
            Atomic.get active = 0
        | Eta.Exit.Ok _ | Eta.Exit.Error _ -> false
      in
      List.for_all
        (fun class_ ->
          responses_class_counts.(class_) <-
            responses_class_counts.(class_) + 1;
          let role = class_ / 4 in
          let position = class_ mod 4 in
          let contents =
            insert position [ A.Text "a"; A.Json "{}"; A.Text "b" ]
          in
          let audio_message =
            match role with
            | 0 -> A.User contents
            | 1 -> A.Assistant { content = contents; tool_calls = [] }
            | 2 -> A.Tool { tool_call_id = "call"; content = contents }
            | _ -> A.User contents
          in
          let messages =
            if role = 3 then [ A.System "system"; audio_message ]
            else [ audio_message ]
          in
          let request = response_request (A.Responses.Messages messages) in
          let tool_callbacks = ref 0 in
          let encode_tool _ =
            incr tool_callbacks;
            Stdlib.Ok (J.object_ [])
          in
          let codec_paths =
            unsupported_ai
              (C.message_item ~provider:"openai"
                 (if role = 1 then "assistant"
                  else if role = 2 then "tool"
                  else if role = 3 then "system"
                  else "user")
                 contents)
            &&
            (if role = 3 then
               (* [System] has no content list in [Eta_ai.message]. The direct
                  [message_item] call above covers system audio; [input_items]
                  can only cover the representable empty System value here. *)
               Result.is_ok
                 (C.input_items ~provider:"openai" (A.System "system"))
             else
               unsupported_ai
                 (C.input_items ~provider:"openai" audio_message))
            && unsupported_ai
                 (C.encode_responses_json ~provider:"openai" ~encode_tool
                    request)
            && unsupported_codec
                 (C.encode_responses_lossless ~provider:"openai"
                    ~map_codec_failure:Fun.id
                    ~encode_tool:(fun _ ->
                      incr tool_callbacks;
                      Stdlib.Ok (J.object_ []))
                    request)
            && unsupported_ai
                 (C.encode_responses ~provider:"openai" ~encode_tool request)
          in
          let provider_callbacks = ref 0 in
          let provider = O.responses_provider () in
          let provider =
            {
              provider with
              A.encode_responses =
                (fun request ->
                  incr provider_callbacks;
                  provider.encode_responses request);
            }
          in
          let http_calls = ref 0 in
          let client =
            H.Client.make_custom ~protocol:H.Client.H1
              ~request:(fun _ ->
                incr http_calls;
                E.pure
                  (H.Response.make ~status:500
                     ~body:(H.Body.Stream.of_bytes []) ()))
              ~stats:(fun () -> E.pure None)
              ~shutdown:(fun () -> E.unit)
          in
          let registrations = Atomic.make 0 in
          let active = Atomic.make 0 in
          let run_ok =
            effect_unsupported registrations active
              (O.responses ~provider client ~api_key:(A.api_key "secret")
                 request)
          in
          let registrations_stream = Atomic.make 0 in
          let active_stream = Atomic.make 0 in
          let stream_ok =
            effect_unsupported registrations_stream active_stream
              (O.stream_responses ~provider client
                 ~api_key:(A.api_key "secret") request)
          in
          codec_paths && unsupported_openai (O.encode_responses request)
          && unsupported_openai
               (O.responses_request ~provider ~api_key:(A.api_key "secret")
                  request)
          && run_ok && stream_ok && !tool_callbacks = 0
          && !provider_callbacks = 0 && !http_calls = 0)
        (List.init 16 Fun.id))

let set_member name value = function
  | `Assoc fields ->
      `Assoc ((name, value) :: List.remove_assoc name fields)
  | json -> json

let remove_member name = function
  | `Assoc fields -> `Assoc (List.remove_assoc name fields)
  | json -> json

let map_first_choice f json =
  match J.member "choices" json with
  | Some (`List (choice :: rest)) ->
      set_member "choices" (`List (f choice :: rest)) json
  | None | Some _ -> json

let map_first_message f =
  map_first_choice (fun choice ->
      match J.member "message" choice with
      | Some message -> set_member "message" (f message) choice
      | None -> choice)

let expect_decode = function
  | Ok _ -> true
  | Error _ -> false

let expect_decode_error raw =
  match O.Chat.decode raw with
  | Error (O.Error.Decode { raw_body = Some actual; _ }) ->
      String.equal raw actual
  | Ok _ | Error _ -> false

let effect_replay_count = ref 0

let property_effect_replay_concurrent_census =
  QCheck.Test.make
    ~name:
      "oachat generated replayed concurrent Chat effects return independent provider responses release bodies and empty the fiber census"
    ~count:40
    (QCheck.make
       ~print:(fun (left, right) ->
         Printf.sprintf "{left=%d;right=%d}" left right)
       QCheck.Gen.(pair nat_small nat_small))
    (fun (left, right) ->
      incr effect_replay_count;
      let ordinal = Atomic.make 0 in
      let releases = Atomic.make 0 in
      let registrations = Atomic.make 0 in
      let active = Atomic.make 0 in
      let ids =
        [|
          Printf.sprintf "chat-left-%d" left;
          Printf.sprintf "chat-right-%d" right;
        |]
      in
      let client =
        H.Client.make_custom ~protocol:H.Client.H1
          ~request:(fun _ ->
            E.sync (fun () ->
                let index = Atomic.fetch_and_add ordinal 1 in
                let raw =
                  audio_response "AA=="
                  |> set_member "id" (J.string ids.(index))
                  |> J.to_string
                in
                let body =
                  H.Body.Stream.of_bytes
                    ~release:(fun () ->
                      E.sync (fun () -> Atomic.incr releases))
                    [ Bytes.of_string raw ]
                in
                H.Response.make ~status:200 ~body ()))
          ~stats:(fun () ->
            E.pure
              (Some
                 {
                   H.Client.protocol = H.Client.H1;
                   active = 0;
                   idle = 0;
                   capacity = 0;
                   opened = 0;
                   released = 0;
                 }))
          ~shutdown:(fun () -> E.unit)
      in
      let request =
        O.Chat.request ~common:(common [ A.User [ A.Text "replay" ] ]) ()
        |> Result.get_ok
      in
      let program =
        O.Chat.run client ~api_key:(A.api_key "not-observed") request
      in
      let exit =
        Eta_test_backend_eio.Backend.run_counting_forks ~registrations ~active
          (E.all [ program; program ])
      in
      match exit with
      | Eta.Exit.Ok responses ->
          let actual =
            responses |> List.map (fun response -> response.O.Chat.id)
            |> List.sort String.compare
          in
          let expected = Array.to_list ids |> List.sort String.compare in
          actual = expected && Atomic.get releases = 2
          && Atomic.get registrations >= 2 && Atomic.get active = 0
      | Eta.Exit.Error _ -> false)

let response_shape_counts = Array.make 11 0

let property_response_shapes =
  QCheck.Test.make
    ~name:
      "oachat generated missing nullable wrong content logprobs finish and choice shapes discriminate"
    ~count:550
    (QCheck.make ~print:string_of_int QCheck.Gen.(0 -- 10))
    (fun case ->
      response_shape_counts.(case) <- response_shape_counts.(case) + 1;
      let base = audio_response "AA==" in
      let json, expected =
        match case with
        | 0 -> (map_first_message (remove_member "content") base, `Ok)
        | 1 -> (map_first_message (set_member "content" `Null) base, `Ok)
        | 2 ->
            ( map_first_message
                (set_member "content"
                   (`List
                     [
                       J.object_
                         [
                           ("type", Some (J.string "text"));
                           ("text", Some (J.string "part"));
                           ("raw_part", Some (J.int 1));
                         ];
                       J.object_
                         [
                           ("type", Some (J.string "refusal"));
                           ("refusal", Some (J.string "no"));
                           ("raw_part", Some (J.int 2));
                         ];
                     ]))
                base,
              `Parts )
        | 3 ->
            (map_first_message (set_member "content" (`Bool true)) base, `Error)
        | 4 ->
            (map_first_choice (remove_member "finish_reason") base, `Error)
        | 5 ->
            (map_first_choice (set_member "finish_reason" `Null) base, `Error)
        | 6 -> (map_first_choice (remove_member "logprobs") base, `No_logprobs)
        | 7 ->
            (map_first_choice (set_member "logprobs" `Null) base, `No_logprobs)
        | 8 ->
            ( map_first_choice
                (set_member "logprobs"
                   (J.object_
                      [
                        ( "content",
                          Some
                            (J.array
                               [
                                 J.object_
                                   [
                                     ("token", Some (J.string "x"));
                                     ("raw_logprob", Some (J.int 8));
                                   ];
                               ]) );
                        ("refusal", Some `Null);
                        ("raw_logprobs", Some (J.int 9));
                      ]))
                base,
              `Logprobs )
        | 9 -> (set_member "choices" (`List []) base, `Error)
        | _ ->
            let second =
              match J.member "choices" base with
              | Some (`List (choice :: _)) ->
                  choice
                  |> set_member "index" (J.int 1)
                  |> set_member "finish_reason" (J.string "length")
                  |> (fun choice ->
                       match J.member "message" choice with
                       | Some message ->
                           set_member "message"
                             (set_member "content" (J.string "second") message)
                             choice
                       | None -> choice)
              | None | Some _ -> assert false
            in
            ( match J.member "choices" base with
            | Some (`List [ first ]) ->
                (set_member "choices" (`List [ first; second ]) base, `Multiple)
            | None | Some _ -> assert false )
      in
      let raw = J.to_string json in
      match (expected, O.Chat.decode raw) with
      | `Ok, Ok _ | `No_logprobs, Ok _ -> true
      | `Error, Error (O.Error.Decode { raw_body = Some actual; _ }) ->
          String.equal raw actual
      | `Parts, Ok response -> (
          match (List.hd response.choices).message.content with
          | Some
              (O.Chat.Content_parts
                [
                  O.Chat.Text_part { raw = first; _ };
                  O.Chat.Refusal_part { raw = second; _ };
                ]) ->
              J.int_member "raw_part" first = Some 1
              && J.int_member "raw_part" second = Some 2
          | _ -> false)
      | `Logprobs, Ok response -> (
          match (List.hd response.choices).logprobs with
          | Some { content = Some [ token ]; raw; _ } ->
              J.int_member "raw_logprobs" raw = Some 9
              && J.int_member "raw_logprob" token = Some 8
          | None | Some _ -> false)
      | `Multiple, Ok response ->
          let neutral = O.Chat.to_eta_ai response in
          List.length response.choices = 2
          && neutral.finish_reasons = [ A.Stop ]
          &&
          (match neutral.message with
          | A.Assistant { content = [ A.Text "visible text" ]; _ } -> true
          | _ -> false)
      | (`Ok | `No_logprobs | `Parts | `Logprobs | `Multiple), Error _
      | `Error, Ok _ ->
          false
      | _ -> false)

let invalid_base64_counts = Array.make 4 0

let property_invalid_input_base64 =
  let gen = QCheck.Gen.(pair (1 -- 4096) (0 -- 3)) in
  QCheck.Test.make
    ~name:
      "oachat generated invalid standard padded base64 mutations reject before provider encoding"
    ~count:400
    (QCheck.make
       ~print:(fun (size, mutation) ->
         Printf.sprintf "{size=%d;mutation=%d}" size mutation)
       gen)
    (fun (size, mutation) ->
      invalid_base64_counts.(mutation) <-
        invalid_base64_counts.(mutation) + 1;
      let bytes = Bytes.make size '\x5a' in
      let canonical = Base64.encode_string (Bytes.to_string bytes) in
      let invalid =
        match mutation with
        | 0 -> "*" ^ String.sub canonical 1 (String.length canonical - 1)
        | 1 -> String.sub canonical 0 (String.length canonical - 1)
        | 2 -> "AB=="
        | _ -> "AAB="
      in
      let request =
        common ~stream:true
          [
            A.User
              [
                A.Audio
                  {
                    data = A.Base64 invalid;
                    format = A.Wav;
                    transcript = None;
                  };
              ];
          ]
      in
      let nominal =
        match O.Chat.request ~common:request () with
        | Error (O.Error.Invalid_request _) -> true
        | Ok _ | Error _ -> false
      in
      let neutral =
        match (O.chat_completions_provider ()).encode_chat request with
        | Error (A.Invalid_request _) -> true
        | Ok _ | Error _ -> false
      in
      let message = List.hd request.prompt in
      let schema_value = C.schema_value ~provider:"openai-compatible" in
      let schema_value_lossless _ raw =
        match J.parse raw with
        | Ok json -> Ok json
        | Error message ->
            (Error (C.Decode { message; raw_body = Some raw }) :
              (_, C.codec_failure) result)
      in
      let invalid_ai = function
        | Error (A.Invalid_request _) -> true
        | Ok _ | Error _ -> false
      in
      let invalid_codec = function
        | Error (C.Invalid_request _) -> true
        | Ok _ | Error _ -> false
      in
      nominal && neutral
      && invalid_ai
           (C.chat_message_json ~provider:"openai-compatible" message)
      && invalid_ai
           (C.encode_chat_json ~provider:"openai-compatible" ~schema_value
              request)
      && invalid_ai
           (C.encode_chat ~provider:"openai-compatible" ~schema_value request)
      && invalid_codec
           (C.encode_chat_lossless ~schema_value:schema_value_lossless request)
      && invalid_ai
           (C.encode_chat_with_thinking ~provider:"openai-compatible"
              ~schema_value request))

let validation_class_counts = Array.make 18 0

let property_shared_chat_validation =
  QCheck.Test.make
    ~name:
      "oachat generated role-format classes share canonical validation across nominal neutral and every public Chat codec path"
    ~count:10
    (QCheck.make
       ~print:(fun (bytes, base64) ->
         Printf.sprintf "{bytes=%S;base64=%b}" (Bytes.to_string bytes) base64)
       QCheck.Gen.(pair bytes_gen bool))
    (fun (bytes, base64) ->
      let formats =
        [| A.Mp3; A.Wav; A.Pcm16; A.Opus; A.G711_alaw; A.G711_ulaw |]
      in
      List.for_all
        (fun class_ ->
          validation_class_counts.(class_) <-
            validation_class_counts.(class_) + 1;
          let role = class_ / 6 in
          let format = formats.(class_ mod 6) in
          let data =
            if base64 then
              A.Base64 (Base64.encode_string (Bytes.to_string bytes))
            else A.Bytes bytes
          in
          let audio = A.Audio { data; format; transcript = None } in
          let message =
            match role with
            | 0 -> A.User [ audio ]
            | 1 -> A.Assistant { content = [ audio ]; tool_calls = [] }
            | _ -> A.Tool { tool_call_id = "call"; content = [ audio ] }
          in
          let tool =
            A.make_tool ~name:"validation_tool"
              ~description:"callback discriminator"
              ~input_schema_json:"{\"type\":\"object\"}" ()
            |> Result.get_ok
          in
          let request =
            { (common ~stream:true [ message ]) with tools = [ tool ] }
          in
          let valid = role = 0 && (format = A.Mp3 || format = A.Wav) in
          let schema_callbacks = ref 0 in
          let schema_value label raw =
            incr schema_callbacks;
            C.schema_value ~provider:"openai-compatible" label raw
          in
          let schema_value_lossless _ raw =
            incr schema_callbacks;
            match J.parse raw with
            | Ok json -> Ok json
            | Error message ->
                (Error (C.Decode { message; raw_body = Some raw }) :
                  (_, C.codec_failure) result)
          in
          let paths =
            [
              Result.is_ok (O.Chat.request ~common:request ());
              Result.is_ok
                ((O.chat_completions_provider ()).encode_chat request);
              Result.is_ok
                (C.chat_message_json ~provider:"openai-compatible" message);
              Result.is_ok
                (C.encode_chat_json ~provider:"openai-compatible" ~schema_value
                   request);
              Result.is_ok
                (C.encode_chat ~provider:"openai-compatible" ~schema_value
                   request);
              Result.is_ok
                (C.encode_chat_lossless ~schema_value:schema_value_lossless
                   request);
              Result.is_ok
                (C.encode_chat_with_thinking ~provider:"openai-compatible"
                   ~schema_value request);
            ]
          in
          List.for_all (( = ) valid) paths
          && !schema_callbacks = (if valid then 4 else 0))
        (List.init 18 Fun.id))

let integer_class_counts = Array.make_matrix 10 8 0

let property_usage_integer_classes =
  QCheck.Test.make
    ~name:
      "oachat generated usage field by numeric representation matrix counts every required optional and rejected-prediction class"
    ~count:5 (QCheck.make ~print:string_of_int QCheck.Gen.nat_small)
    (fun generated ->
      let valid_int = generated mod 1000 in
      let fields =
        [|
          (`Required, "prompt_tokens", "");
          (`Required, "completion_tokens", "");
          (`Required, "total_tokens", "");
          (`Optional, "prompt_tokens_details", "audio_tokens");
          (`Optional, "prompt_tokens_details", "cached_tokens");
          (`Optional, "prompt_tokens_details", "cache_write_tokens");
          (`Optional, "completion_tokens_details", "accepted_prediction_tokens");
          (`Optional, "completion_tokens_details", "audio_tokens");
          (`Optional, "completion_tokens_details", "reasoning_tokens");
          (`Optional, "completion_tokens_details", "rejected_prediction_tokens");
        |]
      in
      List.for_all
        (fun product ->
          let field = product / 8 in
          let class_ = product mod 8 in
          integer_class_counts.(field).(class_) <-
            integer_class_counts.(field).(class_) + 1;
          let required, container, member = fields.(field) in
          let value =
            match class_ with
            | 0 -> None
            | 1 -> Some `Null
            | 2 -> Some (`Int valid_int)
            | 3 -> Some (`Intlit (string_of_int valid_int))
            | 4 -> Some (`Float (float_of_int valid_int +. 0.5))
            | 5 -> Some (`Int (-1))
            | 6 -> Some (`Intlit "999999999999999999999999999999999999")
            | _ -> Some (`String "not-an-integer")
          in
          let valid =
            match required with
            | `Required -> class_ = 2 || class_ = 3
            | `Optional -> class_ <= 3
          in
          let base = audio_response "AA==" in
          let usage = Option.get (J.object_member "usage" base) in
          let usage =
            match required with
            | `Required -> (
                match value with
                | None -> remove_member container usage
                | Some value -> set_member container value usage)
            | `Optional ->
                let details =
                  Option.get (J.object_member container usage)
                  |> (match value with
                     | None -> remove_member member
                     | Some value -> set_member member value)
                in
                set_member container details usage
          in
          let raw = J.to_string (set_member "usage" usage base) in
          expect_decode (O.Chat.decode raw) = valid
          && (valid || expect_decode_error raw))
        (List.init 80 Fun.id))

let tool_moderation_counts = Array.make 4 0

let moderation_result =
  let categories =
    [
      "harassment";
      "harassment/threatening";
      "hate";
      "hate/threatening";
      "illicit";
      "illicit/violent";
      "self-harm";
      "self-harm/instructions";
      "self-harm/intent";
      "sexual";
      "sexual/minors";
      "violence";
      "violence/graphic";
    ]
  in
  J.object_
    [
      ( "categories",
        Some
          (J.object_
             (List.mapi
                (fun index name -> (name, Some (J.bool (index mod 2 = 0))))
                categories)) );
      ( "category_applied_input_types",
        Some
          (J.object_
             (List.map
                (fun name ->
                  (name, Some (J.array [ J.string "text"; J.string "image" ])))
                categories)) );
      ( "category_scores",
        Some
          (J.object_
             (List.mapi
                (fun index name ->
                  (name, Some (`Float (float_of_int index /. 20.0))))
                categories)) );
      ("flagged", Some (J.bool true));
      ("model", Some (J.string "omni-moderation-latest"));
      ("type", Some (J.string "moderation_result"));
      ("raw_result", Some (J.int 31));
    ]

let moderation_success =
  J.object_
    [
      ("model", Some (J.string "omni-moderation-latest"));
      ("results", Some (J.array [ moderation_result ]));
      ("type", Some (J.string "moderation_results"));
      ("raw_success", Some (J.int 32));
    ]

let moderation_error =
  J.object_
    [
      ("code", Some (J.string "moderation_failed"));
      ("message", Some (J.string "unavailable"));
      ("type", Some (J.string "error"));
      ("raw_error", Some (J.int 33));
    ]

let moderation_score_counts = Array.make 11 0

let property_moderation_score_classes =
  QCheck.Test.make
    ~name:
      "oachat generated moderation score representation and inclusive range classes preserve exact decode bodies"
    ~count:5 (QCheck.make ~print:string_of_int QCheck.Gen.nat_small)
    (fun generated ->
      List.for_all
        (fun class_ ->
          moderation_score_counts.(class_) <-
            moderation_score_counts.(class_) + 1;
          let interior = float_of_int ((generated mod 999) + 1) /. 1000.0 in
          let value, valid =
            match class_ with
            | 0 -> (`Int 0, true)
            | 1 -> (`Int 1, true)
            | 2 -> (`Float 0.0, true)
            | 3 -> (`Float 1.0, true)
            | 4 -> (`Float interior, true)
            | 5 -> (`Intlit "0", true)
            | 6 -> (`Intlit "1", true)
            | 7 -> (`Float (-0.0000001), false)
            | 8 -> (`Float 1.0000001, false)
            | 9 -> (`Intlit (String.make 400 '9'), false)
            | _ -> (`String "not-a-score", false)
          in
          let scores =
            Option.get (J.object_member "category_scores" moderation_result)
            |> set_member "harassment" value
          in
          let result = set_member "category_scores" scores moderation_result in
          let success =
            set_member "results" (J.array [ result ]) moderation_success
          in
          let raw =
            audio_response "AA=="
            |> set_member "moderation"
                 (J.object_
                    [
                      ("input", Some success);
                      ("output", Some moderation_error);
                    ])
            |> J.to_string
          in
          expect_decode (O.Chat.decode raw) = valid
          && (valid || expect_decode_error raw))
        (List.init 11 Fun.id))

let property_tool_and_moderation_shapes =
  QCheck.Test.make
    ~name:
      "oachat generated function custom and malformed tools plus moderation success error shapes preserve typed raw records"
    ~count:320
    (QCheck.make ~print:string_of_int QCheck.Gen.(0 -- 3))
    (fun case ->
      tool_moderation_counts.(case) <- tool_moderation_counts.(case) + 1;
      let custom_tool =
        J.object_
          [
            ("id", Some (J.string "custom_1"));
            ("type", Some (J.string "custom"));
            ( "custom",
              Some
                (J.object_
                   [
                     ("name", Some (J.string "shell"));
                     ("input", Some (J.string "echo hi"));
                     ("raw_custom", Some (J.int 41));
                   ]) );
            ("raw_tool", Some (J.int 42));
          ]
      in
      let json =
        audio_response "AA=="
        |> map_first_message
             (set_member "tool_calls"
                (`List
                  [
                    (if case = 1 then custom_tool
                     else if case = 2 then
                       set_member "type" (J.string "future_tool") custom_tool
                     else
                       match
                         J.member "choices" (audio_response "AA==")
                       with
                       | Some (`List (choice :: _)) ->
                           Option.get (J.object_member "message" choice)
                           |> J.array_member "tool_calls" |> Option.get |> List.hd
                       | None | Some _ -> assert false);
                  ]))
        |> set_member "moderation"
             (J.object_
                [
                  ( "input",
                    Some (if case = 3 then moderation_error else moderation_success)
                  );
                  ("output", Some moderation_error);
                  ("raw_moderation", Some (J.int 34));
                ])
      in
      let raw = J.to_string json in
      match (case, O.Chat.decode raw) with
      | 2, Error (O.Error.Decode { raw_body = Some actual; _ }) ->
          String.equal raw actual
      | (0 | 1 | 3), Ok response -> (
          let choice = List.hd response.choices in
          let common_raw_ok =
            J.string_member "unknown_envelope" response.raw = Some "preserved"
            && J.string_member "unknown_choice" choice.raw = Some "choice fact"
            && J.int_member "unknown_message" choice.message.raw = Some 2
            &&
            (match choice.message.audio with
            | Some audio ->
                J.member "unknown_audio" audio.raw = Some (`Bool true)
            | None -> false)
            &&
            match response.usage with
            | Some usage ->
                J.int_member "unknown_usage" usage.raw = Some 8
                && Option.bind usage.prompt_tokens_details (fun details ->
                       J.int_member "unknown_prompt" details.raw)
                   = Some 5
                && Option.bind usage.completion_tokens_details (fun details ->
                       J.int_member "unknown_completion" details.raw)
                   = Some 7
            | None -> false
          in
          let tool_ok =
            match (case, choice.message.tool_calls) with
            | (0 | 3), [ O.Chat.Function_tool_call { raw; function_; _ } ] ->
                J.int_member "unknown_tool" raw = Some 10
                && J.int_member "unknown_function" function_.raw = Some 9
            | 1, [ O.Chat.Custom_tool_call { raw; custom; _ } ] ->
                J.int_member "raw_tool" raw = Some 42
                && J.int_member "raw_custom" custom.raw = Some 41
                && custom.input = "echo hi"
            | _ -> false
          in
          let moderation_ok =
            match response.moderation with
            | Some moderation ->
                J.int_member "raw_moderation" moderation.raw = Some 34
                &&
                (match moderation.output with
                | O.Chat.Moderation_error error ->
                    error.code = "moderation_failed"
                    && J.int_member "raw_error" error.raw = Some 33
                | O.Chat.Moderation_success _ -> false)
                &&
                (match moderation.input with
                | O.Chat.Moderation_error error ->
                    case = 3 && error.message = "unavailable"
                    && J.int_member "raw_error" error.raw = Some 33
                | O.Chat.Moderation_success success ->
                    case <> 3
                    && J.int_member "raw_success" success.raw = Some 32
                    &&
                    match success.results with
                    | [ result ] ->
                        List.length result.categories = 13
                        && List.length result.category_scores = 13
                        && List.length result.category_applied_input_types = 13
                        && J.int_member "raw_result" result.raw = Some 31
                    | _ -> false)
            | None -> false
          in
          let projection_ok =
            if case <> 1 then true
            else
              match (O.Chat.to_eta_ai response).message with
              | A.Assistant { tool_calls = [ call ]; _ } ->
                  call.id = "custom_1" && call.name = "shell"
                  && call.arguments_json = "\"echo hi\""
              | _ -> false
          in
          common_raw_ok && tool_ok && moderation_ok && projection_ok)
      | (0 | 1 | 3), Error _ | 2, Ok _ -> false
      | _ -> false)

let projection_counts = Array.make 6 0

let property_projection_nonfabrication =
  QCheck.Test.make
    ~name:
      "oachat generated missing and inconsistent usage details preserve direct facts without fabricated derivatives"
    ~count:420
    (QCheck.make ~print:string_of_int QCheck.Gen.(0 -- 5))
    (fun case ->
      projection_counts.(case) <- projection_counts.(case) + 1;
      let base = audio_response "AA==" in
      let usage = Option.get (J.object_member "usage" base) in
      let prompt = Option.get (J.object_member "prompt_tokens_details" usage) in
      let completion =
        Option.get (J.object_member "completion_tokens_details" usage)
      in
      let usage =
        match case with
        | 0 ->
            set_member "prompt_tokens_details"
              (set_member "cache_write_tokens" (J.int 1) prompt)
              usage
        | 1 ->
            remove_member "prompt_tokens_details" usage
        | 2 ->
            set_member "prompt_tokens_details"
              (set_member "cache_write_tokens" (J.int 1) prompt)
              usage
            |> remove_member "completion_tokens_details"
        | 3 ->
            set_member "prompt_tokens_details"
              (prompt
              |> set_member "cached_tokens" (J.int max_int)
              |> set_member "cache_write_tokens" (J.int max_int))
              usage
        | 4 ->
            set_member "completion_tokens_details"
              (completion
              |> set_member "reasoning_tokens" (J.int 9)
              |> set_member "audio_tokens" (J.int 9))
              usage
        | _ ->
            set_member "prompt_tokens_details"
              (remove_member "cache_write_tokens" prompt)
              usage
      in
      let raw = J.to_string (set_member "usage" usage base) in
      match O.Chat.decode raw with
      | Error _ -> false
      | Ok response -> (
          match (O.Chat.to_eta_ai response).usage with
          | None -> false
          | Some projected ->
              let expected_uncached =
                if case = 0 || case = 2 then Some 5 else None
              in
              let expected_text =
                if case = 0 || case = 1 || case = 3 || case = 5 then Some 4
                else None
              in
              projected.input_tokens.total = Some 10
              && projected.output_tokens.total = Some 12
              && projected.input_tokens.uncached = expected_uncached
              && projected.output_tokens.text = expected_text
              && projected.output_tokens.reasoning
                 =
                 (if case = 2 then None
                  else Some (if case = 4 then 9 else 2))
              && List.assoc_opt "reasoning_tokens" projected.raw
                 =
                 (if case = 2 then None
                  else Some (if case = 4 then "9" else "2"))
              &&
              if case = 1 then
                List.assoc_opt "completion_audio_tokens" projected.raw = Some "6"
              else true))

let matrix_counts = Array.make (15 * 6) 0

let property_output_matrix =
  let custom =
    O.Voices.custom_id "voice_custom"
    |> Result.map (fun id -> O.Voices.Custom id)
    |> Result.get_ok
  in
  let voices =
    [|
      O.Voices.Built_in Alloy;
      O.Voices.Built_in Ash;
      O.Voices.Built_in Ballad;
      O.Voices.Built_in Coral;
      O.Voices.Built_in Echo;
      O.Voices.Built_in Fable;
      O.Voices.Built_in Onyx;
      O.Voices.Built_in Nova;
      O.Voices.Built_in Sage;
      O.Voices.Built_in Shimmer;
      O.Voices.Built_in Verse;
      O.Voices.Built_in Marin;
      O.Voices.Built_in Cedar;
      O.Voices.Built_in (Other "future-voice");
      custom;
    |]
  in
  let formats =
    [| O.Chat.Wav; Aac; Mp3; Flac; Opus; Pcm16 |]
  in
  QCheck.Test.make
    ~name:
      "oachat generated finite output voice format modality and extra-name matrices discriminate"
    ~count:1800
    (QCheck.make
       ~print:(fun (voice, format) ->
         Printf.sprintf "{voice=%d;format=%d}" voice format)
       QCheck.Gen.(pair (0 -- 14) (0 -- 5)))
    (fun (voice, format) ->
      matrix_counts.((voice * 6) + format) <-
        matrix_counts.((voice * 6) + format) + 1;
      let audio = { O.Chat.voice = voices.(voice); format = formats.(format) } in
      let valid =
        O.Chat.request ~common:(common [ A.User [ A.Text "x" ] ])
          ~modalities:[ O.Chat.Text; O.Chat.Audio ] ~audio
          ~extra_fields:[ ("future", J.int 1) ] ()
        |> (fun request -> Result.bind request O.Chat.encode)
        |> Result.is_ok
      in
      let duplicate_extra =
        match
          O.Chat.request ~common:(common [ A.User [ A.Text "x" ] ])
            ~extra_fields:[ ("future", J.int 1); ("future", J.int 2) ] ()
        with
        | Error (O.Error.Invalid_request _) -> true
        | Ok _ | Error _ -> false
      in
      valid && duplicate_extra)

let modality_class_counts = Array.make 13 0
let owned_extra_counts = Array.make 10 0
let duplicate_extra_count = ref 0
let stream_output_count = ref 0

let property_output_request_validation =
  QCheck.Test.make
    ~name:
      "oachat generated modality symmetry repetitions owned and duplicate extras plus streamed output reject before callbacks with empty census"
    ~count:20
    (QCheck.make
       ~print:(fun bytes -> Printf.sprintf "{extra=%S}" (Bytes.to_string bytes))
       bytes_gen)
    (fun bytes ->
      let output =
        {
          O.Chat.voice = O.Voices.Built_in O.Voices.Alloy;
          format = O.Chat.Wav;
        }
      in
      let cases =
        [|
          ([], None, true);
          ([ O.Chat.Text ], None, true);
          ([ O.Chat.Audio ], Some output, true);
          ([ O.Chat.Text; O.Chat.Audio ], Some output, true);
          ([ O.Chat.Audio; O.Chat.Text ], Some output, true);
          ([ O.Chat.Audio ], None, false);
          ([ O.Chat.Text; O.Chat.Audio ], None, false);
          ([], Some output, false);
          ([ O.Chat.Text ], Some output, false);
          ([ O.Chat.Text; O.Chat.Text ], None, false);
          ([ O.Chat.Audio; O.Chat.Audio ], Some output, false);
          ([ O.Chat.Text; O.Chat.Audio; O.Chat.Text ], Some output, false);
          ([ O.Chat.Audio; O.Chat.Text; O.Chat.Audio ], Some output, false);
        |]
      in
      let modalities_ok =
        Array.to_list cases
        |> List.mapi (fun class_ (modalities, audio, valid) ->
               modality_class_counts.(class_) <-
                 modality_class_counts.(class_) + 1;
               Result.is_ok
                 (O.Chat.request
                    ~common:(common [ A.User [ A.Text "modalities" ] ])
                    ~modalities ?audio ())
               = valid)
        |> List.for_all Fun.id
      in
      let owned =
        [|
          "model";
          "messages";
          "stream";
          "temperature";
          "max_tokens";
          "tools";
          "response_format";
          "modalities";
          "audio";
          "store";
        |]
      in
      let owned_ok =
        Array.to_list owned
        |> List.mapi (fun class_ name ->
               owned_extra_counts.(class_) <- owned_extra_counts.(class_) + 1;
               match
                 O.Chat.request
                   ~common:(common [ A.User [ A.Text "extra" ] ])
                   ~extra_fields:[ (name, J.int class_) ] ()
               with
               | Error (O.Error.Invalid_request _) -> true
               | Ok _ | Error _ -> false)
        |> List.for_all Fun.id
      in
      incr duplicate_extra_count;
      let arbitrary_name =
        "future_" ^ Base64.encode_string (Bytes.to_string bytes)
      in
      let duplicate_ok =
        match
          O.Chat.request ~common:(common [ A.User [ A.Text "extra" ] ])
            ~extra_fields:
              [ (arbitrary_name, J.int 1); (arbitrary_name, J.int 2) ]
            ()
        with
        | Error (O.Error.Invalid_request _) -> true
        | Ok _ | Error _ -> false
      in
      incr stream_output_count;
      let encode_calls = ref 0 in
      let provider = O.chat_completions_provider () in
      let provider =
        {
          provider with
          A.encode_chat =
            (fun request ->
              incr encode_calls;
              provider.encode_chat request);
        }
      in
      let http_calls = ref 0 in
      let client =
        H.Client.make_custom ~protocol:H.Client.H1
          ~request:(fun _ ->
            incr http_calls;
            E.pure
              (H.Response.make ~status:500
                 ~body:(H.Body.Stream.of_bytes []) ()))
          ~stats:(fun () -> E.pure None)
          ~shutdown:(fun () -> E.unit)
      in
      let request =
        O.Chat.request ~common:(common [ A.User [ A.Text "stream" ] ])
          ~modalities:[ O.Chat.Audio ] ~audio:output ()
        |> Result.get_ok
      in
      let registrations = Atomic.make 0 in
      let active = Atomic.make 0 in
      let stream_ok =
        match
          Eta_test_backend_eio.Backend.run_counting_forks ~registrations ~active
            (O.Chat.stream ~provider client ~api_key:(A.api_key "secret") request)
        with
        | Eta.Exit.Error (Eta.Cause.Fail (O.Error.Unsupported _)) ->
            Atomic.get active = 0
        | Eta.Exit.Ok _ | Eta.Exit.Error _ -> false
      in
      modalities_ok && owned_ok && duplicate_ok && stream_ok
      && !encode_calls = 0 && !http_calls = 0)

let fixed_large_audio_witness () =
  let bytes = Bytes.make ((1024 * 1024) + 17) '\xa5' in
  let encoded = Base64.encode_string (Bytes.to_string bytes) in
  match O.Chat.decode (J.to_string (audio_response encoded)) with
  | Error _ -> false
  | Ok response -> (
      match (List.hd response.choices).message.audio with
      | None -> false
      | Some audio -> (
          match O.Chat.audio_bytes audio with
          | Ok decoded -> Bytes.equal bytes decoded
          | Error _ -> false))

let all_positive counts =
  Array.for_all (fun count -> count > 0) counts

let all_equal expected counts =
  Array.for_all (fun count -> count = expected) counts

let fixed_matrix_witness () =
      let custom =
        O.Voices.custom_id "voice_custom"
        |> Result.map (fun id -> O.Voices.Custom id)
      in
      let voices =
        [
          O.Voices.Built_in Alloy;
          O.Voices.Built_in Ash;
          O.Voices.Built_in Ballad;
          O.Voices.Built_in Coral;
          O.Voices.Built_in Echo;
          O.Voices.Built_in Fable;
          O.Voices.Built_in Onyx;
          O.Voices.Built_in Nova;
          O.Voices.Built_in Sage;
          O.Voices.Built_in Shimmer;
          O.Voices.Built_in Verse;
          O.Voices.Built_in Marin;
          O.Voices.Built_in Cedar;
          O.Voices.Built_in (Other "future-voice");
        ]
        @ (match custom with Ok voice -> [ voice ] | Error _ -> [])
      in
      let formats =
        [
          O.Chat.Wav;
          Aac;
          Mp3;
          Flac;
          Opus;
          Pcm16;
        ]
      in
      let outputs =
        List.for_all
          (fun voice ->
            List.for_all
              (fun format ->
                match
                  Result.bind
                    (O.Chat.request
                       ~common:(common [ A.User [ A.Text "hello" ] ])
                       ~modalities:[ O.Chat.Text; O.Chat.Audio ]
                       ~audio:{ voice; format } ())
                    O.Chat.encode
                with
                | Ok raw ->
                    String.contains raw 'a'
                    && Option.is_some
                         (Option.bind
                            (Result.to_option (J.parse raw))
                            (J.object_member "audio"))
                | Error _ -> false)
              formats)
          voices
      in
      let raw_json = audio_response "AQID" in
      let raw = J.to_string raw_json in
      let response_fidelity =
        match O.Chat.decode raw with
        | Error _ -> false
        | Ok response -> (
            match (response.choices, response.usage) with
            | [ choice ], Some usage ->
                response.raw = raw_json
                && choice.raw |> J.int_member "unknown_choice" = None
                && J.string_member "unknown_choice" choice.raw
                   = Some "choice fact"
                && choice.message.raw |> J.int_member "unknown_message"
                   = Some 2
                &&
                (match choice.message.tool_calls with
                | [ O.Chat.Function_tool_call tool ] ->
                    J.int_member "unknown_tool" tool.raw = Some 10
                    && J.int_member "unknown_function" tool.function_.raw
                       = Some 9
                | _ -> false)
                &&
                (match choice.message.audio with
                | Some audio ->
                    audio.data = "AQID"
                    && J.member "unknown_audio" audio.raw = Some (`Bool true)
                | None -> false)
                &&
                Option.bind usage.prompt_tokens_details (fun value ->
                    J.int_member "unknown_prompt" value.raw)
                = Some 5
                &&
                Option.bind usage.completion_tokens_details (fun value ->
                    J.int_member "unknown_completion" value.raw)
                = Some 7
                &&
                let neutral = O.Chat.to_eta_ai response in
                neutral.raw = Some raw
                && neutral.id = Some "chatcmpl_audio"
                && neutral.finish_reasons = [ A.Stop ]
                &&
                (match neutral.message with
                | A.Assistant
                    {
                      content = [ A.Text "visible text" ];
                      tool_calls = [ call ];
                    } ->
                    call.id = "call_1" && call.name = "weather"
                    && call.arguments_json = "{}"
                | _ -> false)
            | _ -> false)
      in
      let invalid_base64 =
        [ "A"; "A==="; "AA=A"; "AA*A"; "===="; "AQI"; "AQID="; "AB==" ]
        |> List.for_all (fun data ->
               match O.Chat.decode (J.to_string (audio_response data)) with
               | Error _ -> false
               | Ok response -> (
                   match response.choices with
                   | [ { message = { audio = Some audio; _ }; _ } ] -> (
                       match O.Chat.audio_bytes audio with
                       | Error
                           (O.Error.Decode { raw_body = Some raw_body; _ }) ->
                           String.equal raw_body (J.to_string audio.raw)
                       | _ -> false)
                   | _ -> false))
      in
      let streaming_input =
        match
          O.Chat.request
            ~common:
              (common ~stream:true
                 [
                   A.User
                     [
                       A.Audio
                         {
                           data = A.Base64 "AA==";
                           format = A.Wav;
                           transcript = None;
                         };
                     ];
                 ])
            ()
        with
        | Ok _ -> true
        | Error _ -> false
      in
      let collision =
        match
          O.Chat.request ~common:(common [ A.User [ A.Text "x" ] ])
            ~extra_fields:[ ("audio", `Null) ] ()
        with
        | Error (O.Error.Invalid_request _) -> true
        | _ -> false
      in
      let duplicate_modalities =
        match
          O.Chat.request ~common:(common [ A.User [ A.Text "x" ] ])
            ~modalities:[ O.Chat.Text; O.Chat.Text ] ()
        with
        | Error (O.Error.Invalid_request _) -> true
        | _ -> false
      in
      let audio_configuration_symmetry =
        let audio =
          { O.Chat.voice = O.Voices.Built_in Alloy; format = O.Chat.Wav }
        in
        (match
           O.Chat.request ~common:(common [ A.User [ A.Text "x" ] ])
             ~audio ()
         with
        | Error (O.Error.Invalid_request _) -> true
        | _ -> false)
        &&
        match
          O.Chat.request ~common:(common [ A.User [ A.Text "x" ] ])
            ~modalities:[ O.Chat.Audio ] ()
        with
        | Error (O.Error.Invalid_request _) -> true
        | _ -> false
      in
      let non_user_audio =
        let audio =
          A.Audio
            {
              data = A.Base64 "AA==";
              format = A.Wav;
              transcript = None;
            }
        in
        [ A.Assistant { content = [ audio ]; tool_calls = [] };
          A.Tool { tool_call_id = "call"; content = [ audio ] } ]
        |> List.for_all (fun message ->
               match O.Chat.request ~common:(common [ message ]) () with
               | Error (O.Error.Unsupported _) -> true
               | _ -> false)
      in
      let future_fields =
        match
          O.Chat.request ~common:(common [ A.User [ A.Text "x" ] ])
            ~extra_fields:[ ("future_field", J.string "kept") ] ()
          |> Result.map O.Chat.encode
        with
        | Ok (Ok raw) -> (
            match J.parse raw with
            | Ok json ->
                J.string_member "future_field" json = Some "kept"
            | Error _ -> false)
        | Ok (Error _) | Error _ -> false
      in
      let responses = O.provider () in
      let chat = O.chat_completions_provider () in
      outputs && response_fidelity && invalid_base64 && streaming_input && collision
      && duplicate_modalities && audio_configuration_symmetry && non_user_audio
      && future_fields
      && chat.capabilities.audio_input && chat.capabilities.speech
      && not responses.capabilities.audio_input
      && not responses.capabilities.speech
      && not responses.capabilities.transcription

let () =
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:qcheck_seed
      [
        property_base64_round_trip;
        property_input_wire_fidelity;
        property_responses_rejects_every_audio_position;
        property_effect_replay_concurrent_census;
        property_response_shapes;
        property_invalid_input_base64;
        property_shared_chat_validation;
        property_usage_integer_classes;
        property_moderation_score_classes;
        property_tool_and_moderation_shapes;
        property_projection_nonfabrication;
        property_output_matrix;
        property_output_request_validation;
      ]
  in
  let counters_complete =
    List.for_all all_positive
      [
        response_shape_counts;
        responses_class_counts;
        invalid_base64_counts;
        validation_class_counts;
        moderation_score_counts;
        tool_moderation_counts;
        projection_counts;
        matrix_counts;
        modality_class_counts;
        owned_extra_counts;
      ]
  in
  if
    code <> 0 || !effect_replay_count = 0
    || not (all_equal 5 responses_class_counts)
    || not (all_equal 10 validation_class_counts)
    || not (Array.for_all (all_equal 5) integer_class_counts)
    || not (all_equal 5 moderation_score_counts)
    || not (all_equal 20 modality_class_counts)
    || not (all_equal 20 owned_extra_counts)
    || not counters_complete
    || !duplicate_extra_count <> 20 || !stream_output_count <> 20
    || not (fixed_matrix_witness ())
    || not (fixed_large_audio_witness ())
  then exit 1
