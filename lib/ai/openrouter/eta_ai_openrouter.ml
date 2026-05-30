module A = Eta_ai
module Codec = Eta_ai_openai_codec
module E = Eta.Effect
module H = Eta_http
module Json = A.Json

type attribution = {
  referer : string option;
  title : string option;
}

let attribution ?referer ?title () = { referer; title }

type routing = {
  order : string list;
  only_providers : string list;
  ignored_providers : string list;
  allow_fallbacks : bool option;
  require_parameters : bool option;
  sort : string option;
}

type structured_output = Codec.structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let decode_error_result ?raw message =
  Codec.decode_error_result ?raw ~provider:"openrouter" message

let parse_json raw = Codec.parse_json ~provider:"openrouter" raw

let require_json label raw =
  Codec.schema_value ~provider:"openrouter" label raw

let structured_output ?strict ~name ~schema_json () =
  Codec.structured_output ~schema_value:require_json ?strict ~name ~schema_json
    ()

let invalid_routing message =
  Stdlib.Error (A.Unsupported { provider = "openrouter"; feature = message })

let validate_names field values =
  match
    List.find_opt (fun value -> String.equal (String.trim value) "") values
  with
  | Some _ -> invalid_routing (field ^ " contains an empty provider name")
  | None -> Stdlib.Ok values

let routing ?(order = []) ?(only_providers = []) ?(ignored_providers = [])
    ?allow_fallbacks ?require_parameters ?sort () =
  match validate_names "order" order with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok order -> (
      match validate_names "only" only_providers with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok only_providers -> (
          match validate_names "ignore" ignored_providers with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok ignored_providers ->
              Stdlib.Ok
                {
                  order;
                  only_providers;
                  ignored_providers;
                  allow_fallbacks;
                  require_parameters;
                  sort;
                }))

let string_array values = Json.array (List.map Json.string values)

let routing_json routing =
  Json.object_
    [
      ( "order",
        if routing.order = [] then None else Some (string_array routing.order) );
      ( "only",
        if routing.only_providers = [] then None
        else Some (string_array routing.only_providers) );
      ( "ignore",
        if routing.ignored_providers = [] then None
        else Some (string_array routing.ignored_providers) );
      ("allow_fallbacks", Option.map Json.bool routing.allow_fallbacks);
      ("require_parameters", Option.map Json.bool routing.require_parameters);
      ("sort", Option.map Json.string routing.sort);
    ]

let add_routing routing json =
  match routing with
  | None -> Stdlib.Ok json
  | Some routing -> (
      match json with
      | `Assoc fields ->
          Stdlib.Ok (`Assoc (fields @ [ ("provider", routing_json routing) ]))
      | _ ->
          Stdlib.Error
            (A.Decode_error
               {
                 provider = "openrouter";
                 message = "Responses encoder did not return a JSON object";
                 raw = Some (Json.to_string json);
               }))

let encode_responses ?structured_output ?routing request =
  match
    Codec.encode_responses_json ~provider:"openrouter"
      ~schema_value:require_json ?structured_output request
  with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match add_routing routing json with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok json -> Stdlib.Ok (Json.to_string json))

let encode_chat = encode_responses
let decode_responses raw = Codec.decode_responses ~provider:"openrouter" raw
let decode_chat = decode_responses

let add_input_type input_type json =
  match input_type with
  | None -> Stdlib.Ok json
  | Some input_type -> (
      match json with
      | `Assoc fields ->
          Stdlib.Ok (`Assoc (fields @ [ ("input_type", Json.string input_type) ]))
      | _ ->
          Stdlib.Error
            (A.Decode_error
               {
                 provider = "openrouter";
                 message = "Embeddings encoder did not return a JSON object";
                 raw = Some (Json.to_string json);
               }))

let encode_embeddings_json ?routing ?input_type request =
  match Codec.encode_embeddings_json ~provider:"openrouter" request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Codec.optional_non_empty ~provider:"openrouter" "embedding input_type" input_type with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok input_type -> (
          match add_routing routing json with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok json -> add_input_type input_type json))

let encode_embeddings ?routing ?input_type request =
  match encode_embeddings_json ?routing ?input_type request with
  | Stdlib.Ok json -> Stdlib.Ok (Json.to_string json)
  | Stdlib.Error _ as error -> error

let decode_embeddings raw =
  Codec.decode_embeddings ~usage_extra_raw_names:[ "cost" ] ~provider:"openrouter"
    raw

let openrouter_error_json ?status ?raw json =
  Codec.provider_error_json ?status ?raw ~nested_response_error:true
    ~provider:"openrouter" json

let openrouter_error ?status raw =
  Codec.provider_error ?status ~nested_response_error:true
    ~provider:"openrouter" raw

let decode_error ~status ~headers raw =
  Codec.decode_error ~nested_response_error:true ~provider:"openrouter" ~status
    ~headers raw

let responses_stream_events raw event_name json =
  Codec.responses_stream_events ~nested_response_error:true
    ~provider:"openrouter" raw event_name json

let decode_stream_event event =
  Codec.decode_stream_event ~nested_response_error:true ~provider:"openrouter"
    event

let attribution_headers = function
  | None -> []
  | Some { referer; title } ->
      (match referer with
      | Some referer -> [ ("HTTP-Referer", referer) ]
      | None -> [])
      @
      match title with
      | Some title -> [ ("X-Title", title) ]
      | None -> []

let auth_headers ?attribution ?(extra_headers = []) api_key =
  H.Core.Header.unsafe_of_list
    ([
       ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
       ("Content-Type", "application/json");
       ("Accept", "application/json");
     ]
    @ attribution_headers attribution @ extra_headers)

let capabilities =
  {
    A.streaming = true;
    tools = true;
    tool_choice = true;
    structured_outputs = true;
    text = true;
    image_input = true;
    audio_input = true;
    video_input = true;
    embeddings = true;
    image_generation = true;
    speech = true;
    transcription = true;
    rerank = true;
    video_generation = true;
  }

let provider ?(base_url = "https://openrouter.ai") ?attribution
    ?(extra_headers = []) () =
  {
    A.name = "openrouter";
    base_url;
    chat_path = "/api/v1/responses";
    embeddings_path = Some "/api/v1/embeddings";
    auth_headers = auth_headers ?attribution ~extra_headers;
    capabilities;
    encode_chat = encode_chat;
    decode_chat;
    encode_embeddings = (fun request -> encode_embeddings request);
    decode_embeddings;
    decode_stream_event;
    decode_error;
  }

let make_request = A.provider_request

let responses_request ?structured_output ?routing ?provider:custom_provider
    ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match encode_chat ?structured_output ?routing request with
  | Stdlib.Ok raw -> Stdlib.Ok (make_request provider api_key raw)
  | Stdlib.Error _ as error -> error

let chat_completions_request = responses_request

let embeddings_request ?routing ?input_type ?provider:custom_provider ~api_key
    request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match encode_embeddings ?routing ?input_type request with
  | Stdlib.Ok raw -> A.provider_embeddings_request provider api_key raw
  | Stdlib.Error _ as error -> error

let perform_chat = A.perform_chat
let perform_stream = A.perform_stream
let perform_embeddings = A.perform_embeddings

let with_json_fields extra fields =
  Json.object_ (fields @ List.map (fun (name, value) -> (name, Some value)) extra)

let base64_table =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

let base64_encode input =
  let len = String.length input in
  let out = Buffer.create (((len + 2) / 3) * 4) in
  let rec loop index =
    if index < len then (
      let b0 = Char.code input.[index] in
      let b1 = if index + 1 < len then Char.code input.[index + 1] else 0 in
      let b2 = if index + 2 < len then Char.code input.[index + 2] else 0 in
      Buffer.add_char out base64_table.[b0 lsr 2];
      Buffer.add_char out base64_table.[((b0 land 0x03) lsl 4) lor (b1 lsr 4)];
      if index + 1 < len then
        Buffer.add_char out base64_table.[((b1 land 0x0f) lsl 2) lor (b2 lsr 6)]
      else Buffer.add_char out '=';
      if index + 2 < len then Buffer.add_char out base64_table.[b2 land 0x3f]
      else Buffer.add_char out '=';
      loop (index + 3))
  in
  loop 0;
  Buffer.contents out

let encode_speech (request : A.Speech.request) =
  if String.equal (String.trim request.input) "" then
    invalid_routing "speech input must not be empty"
  else if String.equal (String.trim request.voice) "" then
    invalid_routing "speech voice must not be empty"
  else if Option.is_some request.instructions then
    invalid_routing "speech instructions"
  else
    let speed = Option.bind request.speed Json.float in
    if Option.is_some request.speed && Option.is_none speed then
      invalid_routing "speech speed must be finite"
    else
      Stdlib.Ok
        (with_json_fields request.extra
           [
             ("model", Some (Json.string request.model));
             ("input", Some (Json.string request.input));
             ("voice", Some (Json.string request.voice));
             ("response_format", Option.map Json.string request.response_format);
             ("speed", speed);
           ]
        |> Json.to_string)

let decode_speech_response (body, headers) =
  { A.Speech.content_type = H.Core.Header.get "content-type" headers; audio = body }

let transcription_format (file : A.binary_file) =
  let content_type = String.lowercase_ascii file.content_type in
  let filename = String.lowercase_ascii file.filename in
  let has value =
    String.ends_with ~suffix:("/" ^ value) content_type
    || String.ends_with ~suffix:("." ^ value) filename
    || String.ends_with ~suffix:("-" ^ value) content_type
  in
  if has "wav" then Stdlib.Ok "wav"
  else if has "mp3" || String.equal content_type "audio/mpeg" then Stdlib.Ok "mp3"
  else if has "flac" then Stdlib.Ok "flac"
  else if has "m4a" || String.equal content_type "audio/mp4" then Stdlib.Ok "m4a"
  else if has "ogg" then Stdlib.Ok "ogg"
  else if has "webm" then Stdlib.Ok "webm"
  else if has "aac" then Stdlib.Ok "aac"
  else invalid_routing "transcription file content_type must identify a supported audio format"

let encode_transcription (request : A.Transcription.request) =
  if Option.is_some request.prompt then
    invalid_routing "transcription prompt"
  else if Option.is_some request.response_format then
    invalid_routing "transcription response_format"
  else if request.extra_fields <> [] then
    invalid_routing "transcription extra fields"
  else
  match transcription_format request.file with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok format ->
      let data = base64_encode (Bytes.to_string request.file.data) in
      let temperature = Option.bind request.temperature Json.float in
      if Option.is_some request.temperature && Option.is_none temperature then
        invalid_routing "transcription temperature must be finite"
      else
        Stdlib.Ok
          (Json.object_
             [
               ("model", Some (Json.string request.model));
               (
                 "input_audio",
                 Some
                   (Json.object_
                      [
                        ("data", Some (Json.string data));
                        ("format", Some (Json.string format));
                      ]) );
               ("language", Option.map Json.string request.language);
               ("temperature", temperature);
             ]
          |> Json.to_string)

let decode_transcription raw =
  match parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json ->
      Stdlib.Ok
        {
          A.Transcription.text = Json.string_member "text" json;
          usage = Option.map Codec.usage (Json.object_member "usage" json);
          raw = Some raw;
        }

let encode_rerank (request : A.Rerank.request) =
  match Codec.non_empty_list ~provider:"openrouter" "rerank documents" request.documents with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok documents ->
      Stdlib.Ok
        (Json.object_
           [
             ("model", Some (Json.string request.model));
             ("query", Some (Json.string request.query));
             ("documents", Some (Json.array (List.map Json.string documents)));
             ("top_n", Option.map Json.int request.top_n);
           ]
        |> Json.to_string)

let float_member name json =
  match Json.member name json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | Some (`Intlit value) -> float_of_string_opt value
  | _ -> None

let rerank_result json =
  let document =
    Option.bind (Json.object_member "document" json)
      (Json.string_member "text")
  in
  match Json.int_member "index" json with
  | Some index ->
      Stdlib.Ok
        { A.Rerank.index; score = float_member "relevance_score" json; document = document }
  | None -> decode_error_result "rerank result missing index"

let decode_rerank raw =
  match parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.array_member "results" json with
      | None -> decode_error_result ~raw "rerank response missing results"
      | Some results -> (
          match Codec.result_all (List.map rerank_result results) with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok results ->
              Stdlib.Ok
                {
                  A.Rerank.id = Json.string_member "id" json;
                  model = Json.string_member "model" json;
                  provider = Json.string_member "provider" json;
                  results;
                  usage = Option.map Codec.usage (Json.object_member "usage" json);
                  raw = Some raw;
                }))

let encode_video (request : A.Video.request) =
  if String.equal (String.trim request.prompt) "" then
    invalid_routing "video prompt must not be empty"
  else
    Stdlib.Ok
      (with_json_fields request.extra
         [
           ("model", Some (Json.string request.model));
           ("prompt", Some (Json.string request.prompt));
           ("aspect_ratio", Option.map Json.string request.aspect_ratio);
           ("duration", Option.map Json.int request.duration);
           ("resolution", Option.map Json.string request.resolution);
         ]
      |> Json.to_string)

let usage json =
  let raw_value name = Json.scalar_string_member name json |> Option.value ~default:"" in
  { A.input_tokens = None; output_tokens = None; total_tokens = None; raw = [ ("cost", raw_value "cost"); ("is_byok", raw_value "is_byok") ] }

let decode_video raw =
  match parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.string_member "id" json with
      | None -> decode_error_result ~raw "video response missing id"
      | Some id ->
          Stdlib.Ok
            {
              A.Video.id;
              generation_id = Json.string_member "generation_id" json;
              status = Json.string_member "status" json;
              polling_url = Json.string_member "polling_url" json;
              urls =
                Json.array_member "unsigned_urls" json |> Option.value ~default:[]
                |> List.filter_map (function `String value -> Some value | _ -> None);
              error = Json.string_member "error" json;
              usage = Option.map usage (Json.object_member "usage" json);
              raw = Some raw;
            })

let validate_job_id job_id =
  if String.equal (String.trim job_id) "" then invalid_routing "video job_id must not be empty"
  else if String.contains job_id '/' || String.contains job_id '?' || String.contains job_id '#' then
    invalid_routing "video job_id contains an invalid path character"
  else Stdlib.Ok job_id

let decode_video_content (body, headers) =
  { A.Video.content_type = H.Core.Header.get "content-type" headers; bytes = body }

let encode_image_generation (request : A.Image.request) =
  match request.model with
  | None -> invalid_routing "image generation model is required"
  | Some model ->
      if String.equal (String.trim request.prompt) "" then
        invalid_routing "image generation prompt must not be empty"
      else if Option.is_some request.n then invalid_routing "image generation n"
      else if Option.is_some request.quality then
        invalid_routing "image generation quality"
      else if Option.is_some request.response_format then
        invalid_routing "image generation response_format"
      else if Option.is_some request.user then
        invalid_routing "image generation user"
      else
        let image_config =
          match request.size with
          | None -> None
          | Some size ->
              Some (Json.object_ [ ("image_size", Some (Json.string size)) ])
        in
        Stdlib.Ok
          (with_json_fields request.extra
             [
               ("model", Some (Json.string model));
               (
                 "messages",
                 Some
                   (Json.array
                      [
                        Json.object_
                          [
                            ("role", Some (Json.string "user"));
                            ("content", Some (Json.string request.prompt));
                          ];
                      ]) );
               (
                 "modalities",
                 Some (Json.array [ Json.string "image"; Json.string "text" ]) );
               ("image_config", image_config);
             ]
          |> Json.to_string)

let decode_image_generation raw =
  match parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.array_member "choices" json with
      | Some (choice :: _) -> (
          match Json.object_member "message" choice with
          | None -> decode_error_result ~raw "image generation choice missing message"
          | Some message ->
              let images =
                Json.array_member "images" message |> Option.value ~default:[]
                |> List.filter_map (fun item ->
                       let image_json = Json.object_member "image_url" item in
                       let url = Option.bind image_json (Json.string_member "url") in
                       Option.map
                         (fun url ->
                           {
                             A.Image.url = Some url;
                             base64 = None;
                             revised_prompt = None;
                           })
                         url)
              in
              Stdlib.Ok
                {
                  A.Image.created = Json.int_member "created" json;
                  images;
                  usage = Option.map Codec.usage (Json.object_member "usage" json);
                  raw = Some raw;
                })
      | _ -> decode_error_result ~raw "image generation response missing choices")

let responses ?structured_output ?routing ?provider:custom_provider client
    ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match
    responses_request ?structured_output ?routing ~provider ~api_key request
  with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider request (perform_chat provider client http_request)

let chat_completions = responses

let embeddings ?routing ?input_type ?provider:custom_provider client ~api_key
    request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match embeddings_request ?routing ?input_type ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_embeddings_span provider request
        (perform_embeddings provider client http_request)

let speech_request ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match encode_speech request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok (A.provider_post_request provider ~path:"/api/v1/audio/speech" api_key raw)

let speech ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match speech_request ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_binary ~max_bytes:(64 * 1024 * 1024) provider client http_request
      |> E.map decode_speech_response

let transcription_request ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match encode_transcription request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok
        (A.provider_post_request provider ~path:"/api/v1/audio/transcriptions" api_key raw)

let transcription ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match transcription_request ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_raw provider client http_request
      |> E.bind (fun raw ->
             match decode_transcription raw with
             | Stdlib.Ok response -> E.pure response
             | Stdlib.Error error -> E.fail error)

let rerank_request ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match encode_rerank request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok (A.provider_post_request provider ~path:"/api/v1/rerank" api_key raw)

let rerank ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match rerank_request ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_raw provider client http_request
      |> E.bind (fun raw ->
             match decode_rerank raw with
             | Stdlib.Ok response -> E.pure response
             | Stdlib.Error error -> E.fail error)

let video_request ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match encode_video request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok (A.provider_post_request provider ~path:"/api/v1/videos" api_key raw)

let video ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match video_request ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_raw provider client http_request
      |> E.bind (fun raw ->
             match decode_video raw with
             | Stdlib.Ok response -> E.pure response
             | Stdlib.Error error -> E.fail error)

let video_get_request ?provider:custom_provider ~api_key ~job_id () =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match validate_job_id job_id with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok job_id ->
      Stdlib.Ok
        (A.provider_get_request provider ~path:("/api/v1/videos/" ^ job_id) api_key)

let video_get ?provider:custom_provider client ~api_key ~job_id =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match video_get_request ~provider ~api_key ~job_id () with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_raw provider client http_request
      |> E.bind (fun raw ->
             match decode_video raw with
             | Stdlib.Ok response -> E.pure response
             | Stdlib.Error error -> E.fail error)

let video_content_request ?provider:custom_provider ~api_key
    (request : A.Video.content_request) =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match validate_job_id request.job_id with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok job_id ->
      let index = Option.value ~default:0 request.index in
      if index < 0 then invalid_routing "video content index must be non-negative"
      else
        Stdlib.Ok
          (A.provider_get_request provider
             ~path:("/api/v1/videos/" ^ job_id ^ "/content?index=" ^ string_of_int index)
             api_key)

let video_content ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match video_content_request ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_binary ~max_bytes:(256 * 1024 * 1024) provider client http_request
      |> E.map decode_video_content

let image_generation_request ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match encode_image_generation request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok
        (A.provider_post_request provider ~path:"/api/v1/chat/completions"
           api_key raw)

let image_generation ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match image_generation_request ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_raw provider client http_request
      |> E.bind (fun raw ->
             match decode_image_generation raw with
             | Stdlib.Ok response -> E.pure response
             | Stdlib.Error error -> E.fail error)

let stream_responses ?structured_output ?routing ?provider:custom_provider
    client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  let request = { request with A.stream = true } in
  match
    responses_request ?structured_output ?routing ~provider ~api_key request
  with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_stream_span provider request
        (perform_stream provider client http_request)

let stream_chat_completions = stream_responses

module Chat = struct
  include A.Provider.Chat

  let encode_responses = encode_responses
  let responses_request = responses_request
  let responses = responses
  let stream_responses = stream_responses
end

module Embeddings = struct
  include A.Provider.Embeddings

  let encode_with_routing = encode_embeddings
  let request_with_routing = embeddings_request
  let run_with_routing = embeddings
end

module Images = struct
  let generate ~provider client ~api_key request =
    image_generation ~provider client ~api_key request
end

module Speech = struct
  let create ~provider client ~api_key request =
    speech ~provider client ~api_key request
end

module Transcriptions = struct
  let create ~provider client ~api_key request =
    transcription ~provider client ~api_key request
end

module Rerank = struct
  let run ~provider client ~api_key request =
    rerank ~provider client ~api_key request
end

module Video = struct
  let create ~provider client ~api_key request =
    video ~provider client ~api_key request

  let get ~provider client ~api_key ~job_id =
    video_get ~provider client ~api_key ~job_id

  let content ~provider client ~api_key request =
    video_content ~provider client ~api_key request
end
