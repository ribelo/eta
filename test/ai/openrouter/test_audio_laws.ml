module A = Eta_ai
module C = Eta_ai_openai_codec
module O = Eta_ai_openrouter
module J = A.Json

let qcheck_seed = Random.State.make [| 0x0A; 0xC4A7; 0x22 |]

let bytes_gen =
  QCheck.Gen.map
    (fun values ->
      let bytes = Bytes.create (List.length values) in
      List.iteri (fun index value -> Bytes.set_uint8 bytes index value) values;
      bytes)
    QCheck.Gen.(list_size (0 -- 4096) (0 -- 255))

let request audio : A.tool A.Responses.request =
  {
    model = "openrouter/auto";
    input = A.Responses.Messages [ A.User [ A.Audio audio ] ];
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

let wire_audio raw =
  match J.parse raw with
  | Error _ -> None
  | Ok json -> (
      match J.array_member "input" json with
      | Some [ message ] -> (
          match J.array_member "content" message with
          | Some [ part ] -> (
              match J.object_member "input_audio" part with
              | Some audio -> (
                  match
                    (J.string_member "data" audio, J.string_member "format" audio)
                  with
                  | Some data, Some format -> Some (data, format)
                  | _ -> None)
              | None -> None)
          | None | Some _ -> None)
      | None | Some _ -> None)

let formats =
  [|
    (A.Pcm16, "pcm16");
    (A.G711_alaw, "g711_alaw");
    (A.G711_ulaw, "g711_ulaw");
    (A.Mp3, "mp3");
    (A.Opus, "opus");
    (A.Wav, "wav");
  |]

let format_counts = Array.make 6 0

let property_openrouter_audio_wire =
  QCheck.Test.make
    ~name:
      "oachat-22 generated arbitrary bytes and base64 preserve exact OpenRouter audio wire through dedicated codec and provider"
    ~count:120
    (QCheck.make
       ~print:(fun (bytes, format) ->
         Printf.sprintf "{bytes=%S;format=%d}" (Bytes.to_string bytes) format)
       QCheck.Gen.(pair bytes_gen (0 -- 5)))
    (fun (bytes, format_index) ->
      format_counts.(format_index) <- format_counts.(format_index) + 1;
      let format, format_wire = formats.(format_index) in
      let encoded = Base64.encode_string (Bytes.to_string bytes) in
      let check data =
        let request = request { A.data = data; format; transcript = None } in
        let dedicated =
          C.encode_openrouter_responses
            ~encode_tool:(fun _ -> Ok (J.object_ []))
            request
        in
        let provider = O.encode_responses request in
        match (dedicated, provider) with
        | Ok dedicated, Ok provider ->
            wire_audio dedicated = Some (encoded, format_wire)
            && wire_audio provider = Some (encoded, format_wire)
        | Ok _, Error _ | Error _, Ok _ | Error _, Error _ -> false
      in
      check (A.Bytes bytes) && check (A.Base64 encoded))

let () =
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:qcheck_seed
      [ property_openrouter_audio_wire ]
  in
  if code <> 0 || not (Array.for_all (fun count -> count > 0) format_counts)
  then exit 1
