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

let invalid_embeddings message =
  Stdlib.Error (A.Unsupported { provider = "openrouter"; feature = message })

let non_empty_list label = function
  | [] -> invalid_embeddings (label ^ " must not be empty")
  | values -> Stdlib.Ok values

let int_array values = Json.array (List.map Json.int values)

let embedding_input_json (input : A.embedding_input) =
  match input with
  | A.Embedding_text text -> Stdlib.Ok (Json.string text)
  | A.Embedding_texts texts -> (
      match non_empty_list "embedding input" texts with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok texts -> Stdlib.Ok (Json.array (List.map Json.string texts)))
  | A.Embedding_tokens tokens -> (
      match non_empty_list "embedding token input" tokens with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok tokens -> Stdlib.Ok (int_array tokens))
  | A.Embedding_token_batches batches -> (
      match non_empty_list "embedding token batch input" batches with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok batches -> (
          match
            Codec.result_all
              (List.map (non_empty_list "embedding token input") batches)
          with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok batches ->
              Stdlib.Ok (Json.array (List.map int_array batches))))
  | A.Embedding_raw_json raw -> parse_json raw

let dimensions_json = function
  | None -> Stdlib.Ok None
  | Some dimensions when dimensions > 0 -> Stdlib.Ok (Some (Json.int dimensions))
  | Some _ -> invalid_embeddings "embedding dimensions must be positive"

let optional_non_empty label = function
  | None -> Stdlib.Ok None
  | Some value when String.equal (String.trim value) "" ->
      invalid_embeddings (label ^ " must not be empty")
  | Some value -> Stdlib.Ok (Some value)

let encoding_format_json = function
  | None -> Stdlib.Ok None
  | Some ("float" | "base64" as value) -> Stdlib.Ok (Some (Json.string value))
  | Some _ -> invalid_embeddings "embedding encoding_format must be float or base64"

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

let encode_embeddings_json ?routing ?input_type (request : A.embedding_request)
    =
  match embedding_input_json request.embedding_input with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok input -> (
      match dimensions_json request.dimensions with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok dimensions -> (
      match encoding_format_json request.encoding_format with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok encoding_format -> (
      match optional_non_empty "embedding user" request.user with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok user -> (
      match optional_non_empty "embedding input_type" input_type with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok input_type ->
          let json =
            Json.object_
              [
                ("model", Some (Json.string request.embedding_model));
                ("input", Some input);
                ("encoding_format", encoding_format);
                ("dimensions", dimensions);
                ("user", Option.map Json.string user);
              ]
          in
          match add_routing routing json with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok json -> add_input_type input_type json))))

let encode_embeddings ?routing ?input_type request =
  match encode_embeddings_json ?routing ?input_type request with
  | Stdlib.Ok json -> Stdlib.Ok (Json.to_string json)
  | Stdlib.Error _ as error -> error

let decode_float ~raw json =
  match json with
  | `Float value -> Stdlib.Ok value
  | `Int value -> Stdlib.Ok (float_of_int value)
  | `Intlit value -> (
      match float_of_string_opt value with
      | Some value -> Stdlib.Ok value
      | None ->
          decode_error_result ~raw "embedding vector contains invalid number")
  | _ -> decode_error_result ~raw "embedding vector contains non-number value"

let decode_embedding_vector ~raw json =
  match json with
  | `List values -> (
      match Codec.result_all (List.map (decode_float ~raw) values) with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok values -> Stdlib.Ok (A.Embedding_float values))
  | `String value -> Stdlib.Ok (A.Embedding_base64 value)
  | _ -> decode_error_result ~raw "embedding must be a float array or base64 string"

let decode_embedding_item ~raw json =
  match Json.member "embedding" json with
  | None -> decode_error_result ~raw "embedding item missing embedding"
  | Some embedding_json -> (
      match decode_embedding_vector ~raw embedding_json with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok embedding ->
          Stdlib.Ok
            { A.embedding; embedding_index = Json.int_member "index" json })

let embedding_usage json =
  let input_tokens =
    match Json.int_member "prompt_tokens" json with
    | Some _ as value -> value
    | None -> Json.int_member "input_tokens" json
  in
  let total_tokens = Json.int_member "total_tokens" json in
  let raw_value name =
    Json.scalar_string_member name json |> Option.value ~default:""
  in
  {
    A.embedding_input_tokens = input_tokens;
    embedding_total_tokens = total_tokens;
    embedding_raw =
      [
        ("prompt_tokens", raw_value "prompt_tokens");
        ("input_tokens", raw_value "input_tokens");
        ("total_tokens", raw_value "total_tokens");
        ("cost", raw_value "cost");
      ];
  }

let decode_embeddings raw =
  match parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.array_member "data" json with
      | None -> decode_error_result ~raw "embeddings response missing data"
      | Some data -> (
          match Codec.result_all (List.map (decode_embedding_item ~raw) data) with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok embeddings ->
              Stdlib.Ok
                {
                  A.embedding_id = Json.string_member "id" json;
                  embedding_model = Json.string_member "model" json;
                  embeddings;
                  embedding_usage =
                    Option.map embedding_usage (Json.object_member "usage" json);
                  embedding_raw = Some raw;
                }))

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

let encode_speech (request : A.speech_request) =
  if String.equal (String.trim request.speech_input) "" then
    invalid_routing "speech input must not be empty"
  else if String.equal (String.trim request.speech_voice) "" then
    invalid_routing "speech voice must not be empty"
  else if Option.is_some request.speech_instructions then
    invalid_routing "speech instructions"
  else
    let speed = Option.bind request.speech_speed Json.float in
    if Option.is_some request.speech_speed && Option.is_none speed then
      invalid_routing "speech speed must be finite"
    else
      Stdlib.Ok
        (with_json_fields request.speech_extra
           [
             ("model", Some (Json.string request.speech_model));
             ("input", Some (Json.string request.speech_input));
             ("voice", Some (Json.string request.speech_voice));
             ("response_format", Option.map Json.string request.speech_response_format);
             ("speed", speed);
           ]
        |> Json.to_string)

let decode_speech_response (body, headers) =
  { A.speech_content_type = H.Core.Header.get "content-type" headers; speech_audio = body }

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

let encode_transcription (request : A.transcription_request) =
  if Option.is_some request.transcription_prompt then
    invalid_routing "transcription prompt"
  else if Option.is_some request.transcription_response_format then
    invalid_routing "transcription response_format"
  else if request.transcription_extra_fields <> [] then
    invalid_routing "transcription extra fields"
  else
  match transcription_format request.transcription_file with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok format ->
      let data = base64_encode (Bytes.to_string request.transcription_file.data) in
      let temperature = Option.bind request.transcription_temperature Json.float in
      if Option.is_some request.transcription_temperature && Option.is_none temperature then
        invalid_routing "transcription temperature must be finite"
      else
        Stdlib.Ok
          (Json.object_
             [
               ("model", Some (Json.string request.transcription_model));
               (
                 "input_audio",
                 Some
                   (Json.object_
                      [
                        ("data", Some (Json.string data));
                        ("format", Some (Json.string format));
                      ]) );
               ("language", Option.map Json.string request.transcription_language);
               ("temperature", temperature);
             ]
          |> Json.to_string)

let decode_transcription raw =
  match parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json ->
      Stdlib.Ok
        {
          A.transcription_text = Json.string_member "text" json;
          transcription_usage = Option.map Codec.usage (Json.object_member "usage" json);
          transcription_raw = Some raw;
        }

let encode_rerank (request : A.rerank_request) =
  match non_empty_list "rerank documents" request.rerank_documents with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok documents ->
      Stdlib.Ok
        (Json.object_
           [
             ("model", Some (Json.string request.rerank_model));
             ("query", Some (Json.string request.rerank_query));
             ("documents", Some (Json.array (List.map Json.string documents)));
             ("top_n", Option.map Json.int request.rerank_top_n);
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
  | Some rerank_index ->
      Stdlib.Ok
        { A.rerank_index; rerank_score = float_member "relevance_score" json; rerank_document = document }
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
          | Stdlib.Ok rerank_results ->
              Stdlib.Ok
                {
                  A.rerank_id = Json.string_member "id" json;
                  rerank_model = Json.string_member "model" json;
                  rerank_provider = Json.string_member "provider" json;
                  rerank_results;
                  rerank_usage = Option.map Codec.usage (Json.object_member "usage" json);
                  rerank_raw = Some raw;
                }))

let encode_video (request : A.video_request) =
  if String.equal (String.trim request.video_prompt) "" then
    invalid_routing "video prompt must not be empty"
  else
    Stdlib.Ok
      (with_json_fields request.video_extra
         [
           ("model", Some (Json.string request.video_model));
           ("prompt", Some (Json.string request.video_prompt));
           ("aspect_ratio", Option.map Json.string request.video_aspect_ratio);
           ("duration", Option.map Json.int request.video_duration);
           ("resolution", Option.map Json.string request.video_resolution);
         ]
      |> Json.to_string)

let video_usage json =
  let raw_value name = Json.scalar_string_member name json |> Option.value ~default:"" in
  { A.input_tokens = None; output_tokens = None; total_tokens = None; raw = [ ("cost", raw_value "cost"); ("is_byok", raw_value "is_byok") ] }

let decode_video raw =
  match parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.string_member "id" json with
      | None -> decode_error_result ~raw "video response missing id"
      | Some video_id ->
          Stdlib.Ok
            {
              A.video_id;
              video_generation_id = Json.string_member "generation_id" json;
              video_status = Json.string_member "status" json;
              video_polling_url = Json.string_member "polling_url" json;
              video_urls =
                Json.array_member "unsigned_urls" json |> Option.value ~default:[]
                |> List.filter_map (function `String value -> Some value | _ -> None);
              video_error = Json.string_member "error" json;
              video_usage = Option.map video_usage (Json.object_member "usage" json);
              video_raw = Some raw;
            })

let validate_job_id job_id =
  if String.equal (String.trim job_id) "" then invalid_routing "video job_id must not be empty"
  else if String.contains job_id '/' || String.contains job_id '?' || String.contains job_id '#' then
    invalid_routing "video job_id contains an invalid path character"
  else Stdlib.Ok job_id

let decode_video_content (body, headers) =
  { A.video_content_type = H.Core.Header.get "content-type" headers; video_bytes = body }

let encode_image_generation (request : A.image_generation_request) =
  match request.image_model with
  | None -> invalid_routing "image generation model is required"
  | Some model ->
      if String.equal (String.trim request.image_prompt) "" then
        invalid_routing "image generation prompt must not be empty"
      else if Option.is_some request.image_n then invalid_routing "image generation n"
      else if Option.is_some request.image_quality then
        invalid_routing "image generation quality"
      else if Option.is_some request.image_response_format then
        invalid_routing "image generation response_format"
      else if Option.is_some request.image_user then
        invalid_routing "image generation user"
      else
        let image_config =
          match request.image_size with
          | None -> None
          | Some image_size ->
              Some (Json.object_ [ ("image_size", Some (Json.string image_size)) ])
        in
        Stdlib.Ok
          (with_json_fields request.image_extra
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
                            ("content", Some (Json.string request.image_prompt));
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
                         (fun image_url ->
                           {
                             A.image_url = Some image_url;
                             image_base64 = None;
                             image_revised_prompt = None;
                           })
                         url)
              in
              Stdlib.Ok
                {
                  A.image_created = Json.int_member "created" json;
                  images;
                  image_usage = Option.map Codec.usage (Json.object_member "usage" json);
                  image_raw = Some raw;
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

let video_content_request ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match validate_job_id request.A.video_job_id with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok job_id ->
      let index = Option.value ~default:0 request.video_index in
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
