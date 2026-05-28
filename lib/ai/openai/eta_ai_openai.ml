module A = Eta_ai
module Codec = Eta_ai_openai_codec
module E = Eta.Effect
module Common = Common
module H = Eta_http
module Json = A.Json

type structured_output = Common.structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let structured_output = Common.structured_output
let encode_chat = Chat.encode
let encode_responses = Responses.encode
let decode_chat = Chat.decode
let decode_responses = Responses.decode
let decode_stream_event = Stream_codec.decode_event
let decode_error = Common.decode_error
module Realtime = Realtime

let decode_error_result ?raw message =
  Stdlib.Error (A.Decode_error { provider = "openai"; message; raw })

let parse_json raw =
  match Json.parse raw with
  | Stdlib.Ok json -> Stdlib.Ok json
  | Stdlib.Error message -> decode_error_result ~raw message

let unsupported feature =
  Stdlib.Error (A.Unsupported { provider = "openai"; feature })

let result_all values =
  let rec loop acc = function
    | [] -> Stdlib.Ok (List.rev acc)
    | Stdlib.Ok value :: rest -> loop (value :: acc) rest
    | Stdlib.Error _ as error :: _ -> error
  in
  loop [] values

let non_empty_list label = function
  | [] -> unsupported (label ^ " must not be empty")
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
            result_all (List.map (non_empty_list "embedding token input") batches)
          with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok batches ->
              Stdlib.Ok (Json.array (List.map int_array batches))))
  | A.Embedding_raw_json raw -> parse_json raw

let positive_int label = function
  | None -> Stdlib.Ok None
  | Some value when value > 0 -> Stdlib.Ok (Some (Json.int value))
  | Some _ -> unsupported (label ^ " must be positive")

let optional_non_empty label = function
  | None -> Stdlib.Ok None
  | Some value when String.equal (String.trim value) "" ->
      unsupported (label ^ " must not be empty")
  | Some value -> Stdlib.Ok (Some value)

let embedding_encoding_format = function
  | None -> Stdlib.Ok None
  | Some ("float" | "base64" as value) -> Stdlib.Ok (Some (Json.string value))
  | Some _ -> unsupported "embedding encoding_format must be float or base64"

let encode_embeddings_json (request : A.embedding_request) =
  match embedding_input_json request.embedding_input with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok input -> (
      match positive_int "embedding dimensions" request.dimensions with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok dimensions -> (
      match embedding_encoding_format request.encoding_format with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok encoding_format -> (
      match optional_non_empty "embedding user" request.user with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok user ->
          Stdlib.Ok
            (Json.object_
               [
                 ("model", Some (Json.string request.embedding_model));
                 ("input", Some input);
                 ("encoding_format", encoding_format);
                 ("dimensions", dimensions);
                 ("user", Option.map Json.string user);
               ]))))

let encode_embeddings request =
  match encode_embeddings_json request with
  | Stdlib.Ok json -> Stdlib.Ok (Json.to_string json)
  | Stdlib.Error _ as error -> error

let decode_float ~raw json =
  match json with
  | `Float value -> Stdlib.Ok value
  | `Int value -> Stdlib.Ok (float_of_int value)
  | `Intlit value -> (
      match float_of_string_opt value with
      | Some value -> Stdlib.Ok value
      | None -> decode_error_result ~raw "embedding vector contains invalid number")
  | _ -> decode_error_result ~raw "embedding vector contains non-number value"

let decode_embedding_vector ~raw json =
  match json with
  | `List values -> (
      match result_all (List.map (decode_float ~raw) values) with
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
          Stdlib.Ok { A.embedding; embedding_index = Json.int_member "index" json })

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
      ];
  }

let decode_embeddings raw =
  match parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.array_member "data" json with
      | None -> decode_error_result ~raw "embeddings response missing data"
      | Some data -> (
          match result_all (List.map (decode_embedding_item ~raw) data) with
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

let auth_headers api_key =
  Eta_http.Core.Header.unsafe_of_list
    [
      ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
      ("Content-Type", "application/json");
      ("Accept", "application/json");
    ]

let capabilities =
  {
    A.streaming = true;
    tools = true;
    tool_choice = true;
    structured_outputs = true;
    text = true;
    image_input = true;
    audio_input = true;
    video_input = false;
    embeddings = true;
    image_generation = true;
    speech = true;
    transcription = true;
    rerank = false;
    video_generation = false;
  }

let chat_completions_provider ?(base_url = "https://api.openai.com") () =
  {
    A.name = "openai";
    base_url;
    chat_path = "/v1/chat/completions";
    embeddings_path = Some "/v1/embeddings";
    auth_headers;
    capabilities;
    encode_chat;
    decode_chat;
    encode_embeddings;
    decode_embeddings;
    decode_stream_event;
    decode_error;
  }

let responses_provider ?(base_url = "https://api.openai.com") () =
  {
    A.name = "openai";
    base_url;
    chat_path = "/v1/responses";
    embeddings_path = Some "/v1/embeddings";
    auth_headers;
    capabilities;
    encode_chat = encode_responses;
    decode_chat = decode_responses;
    encode_embeddings;
    decode_embeddings;
    decode_stream_event;
    decode_error;
  }

let provider ?base_url () = responses_provider ?base_url ()

let make_request = A.provider_request

let chat_completions_request ?structured_output ?provider:custom_provider ~api_key
    request =
  let provider =
    Option.value ~default:(chat_completions_provider ()) custom_provider
  in
  let encoded =
    match structured_output with
    | None -> provider.A.encode_chat request
    | Some _ -> encode_chat ?structured_output request
  in
  match encoded with
  | Stdlib.Ok raw -> Stdlib.Ok (make_request provider api_key raw)
  | Stdlib.Error _ as error -> error

let responses_request ?structured_output ?provider:custom_provider ~api_key
    request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  let encoded =
    match structured_output with
    | None -> provider.A.encode_chat request
    | Some _ -> encode_responses ?structured_output request
  in
  match encoded with
  | Stdlib.Ok raw -> Stdlib.Ok (make_request provider api_key raw)
  | Stdlib.Error _ as error -> error

let perform_chat = A.perform_chat
let perform_stream = A.perform_stream
let perform_embeddings = A.perform_embeddings

let join_url base path =
  let base =
    if String.ends_with ~suffix:"/" base then
      String.sub base 0 (String.length base - 1)
    else base
  in
  let path = if String.starts_with ~prefix:"/" path then path else "/" ^ path in
  base ^ path

let with_json_fields extra fields =
  Json.object_ (fields @ List.map (fun (name, value) -> (name, Some value)) extra)

let encode_image_generation (request : A.image_generation_request) =
  if String.equal (String.trim request.image_prompt) "" then
    unsupported "image prompt must not be empty"
  else
    Stdlib.Ok
      (with_json_fields request.image_extra
         [
           ("model", Option.map Json.string request.image_model);
           ("prompt", Some (Json.string request.image_prompt));
           ("n", Option.map Json.int request.image_n);
           ("size", Option.map Json.string request.image_size);
           ("quality", Option.map Json.string request.image_quality);
           ("response_format", Option.map Json.string request.image_response_format);
           ("user", Option.map Json.string request.image_user);
         ]
      |> Json.to_string)

let generated_image json =
  {
    A.image_url = Json.string_member "url" json;
    image_base64 = Json.string_member "b64_json" json;
    image_revised_prompt = Json.string_member "revised_prompt" json;
  }

let decode_image_response raw =
  match parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.array_member "data" json with
      | None -> decode_error_result ~raw "image response missing data"
      | Some data ->
          Stdlib.Ok
            {
              A.image_created = Json.int_member "created" json;
              images = List.map generated_image data;
              image_usage = Option.map Codec.usage (Json.object_member "usage" json);
              image_raw = Some raw;
            })

let encode_speech (request : A.speech_request) =
  if String.equal (String.trim request.speech_input) "" then
    unsupported "speech input must not be empty"
  else if String.equal (String.trim request.speech_voice) "" then
    unsupported "speech voice must not be empty"
  else
    let speed =
      match request.speech_speed with
      | None -> Stdlib.Ok None
      | Some value -> (
          match Json.float value with
          | Some json -> Stdlib.Ok (Some json)
          | None -> unsupported "speech speed must be finite")
    in
    match speed with
    | Stdlib.Error _ as error -> error
    | Stdlib.Ok speed ->
        Stdlib.Ok
          (with_json_fields request.speech_extra
             [
               ("model", Some (Json.string request.speech_model));
               ("input", Some (Json.string request.speech_input));
               ("voice", Some (Json.string request.speech_voice));
               ("response_format", Option.map Json.string request.speech_response_format);
               ("speed", speed);
               ("instructions", Option.map Json.string request.speech_instructions);
             ]
          |> Json.to_string)

let decode_speech_response (body, headers) =
  {
    A.speech_content_type = H.Core.Header.get "content-type" headers;
    speech_audio = body;
  }

let decode_transcription_response raw =
  match parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json ->
      Stdlib.Ok
        {
          A.transcription_text = Json.string_member "text" json;
          transcription_usage = Option.map Codec.usage (Json.object_member "usage" json);
          transcription_raw = Some raw;
        }

let safe_disposition_value label value =
  if
    String.contains value '\r' || String.contains value '\n'
    || String.contains value '"'
  then unsupported (label ^ " contains an invalid multipart character")
  else Stdlib.Ok value

let multipart_boundary (file : A.binary_file) =
  "eta-ai-" ^ Digest.to_hex (Digest.bytes file.data)

let add_field buffer boundary name value =
  Buffer.add_string buffer ("--" ^ boundary ^ "\r\n");
  Buffer.add_string buffer
    ("Content-Disposition: form-data; name=\"" ^ name ^ "\"\r\n\r\n");
  Buffer.add_string buffer value;
  Buffer.add_string buffer "\r\n"

let multipart_transcription_body (request : A.transcription_request) =
  match safe_disposition_value "transcription filename" request.transcription_file.filename with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok filename ->
      let boundary = multipart_boundary request.transcription_file in
      let buffer = Buffer.create (Bytes.length request.transcription_file.data + 512) in
      add_field buffer boundary "model" request.transcription_model;
      Option.iter (add_field buffer boundary "language") request.transcription_language;
      Option.iter (add_field buffer boundary "prompt") request.transcription_prompt;
      Option.iter
        (add_field buffer boundary "response_format")
        request.transcription_response_format;
      Option.iter
        (fun value -> add_field buffer boundary "temperature" (Printf.sprintf "%.17g" value))
        request.transcription_temperature;
      List.iter
        (fun (name, value) -> add_field buffer boundary name value)
        request.transcription_extra_fields;
      Buffer.add_string buffer ("--" ^ boundary ^ "\r\n");
      Buffer.add_string buffer
        ("Content-Disposition: form-data; name=\"file\"; filename=\""
        ^ filename ^ "\"\r\n");
      Buffer.add_string buffer
        ("Content-Type: " ^ request.transcription_file.content_type ^ "\r\n\r\n");
      Buffer.add_bytes buffer request.transcription_file.data;
      Buffer.add_string buffer ("\r\n--" ^ boundary ^ "--\r\n");
      Stdlib.Ok (boundary, Bytes.of_string (Buffer.contents buffer))

let multipart_request provider ~path api_key boundary body =
  let headers =
    provider.A.auth_headers api_key
    |> H.Core.Header.remove "content-type"
    |> H.Core.Header.unsafe_add "Content-Type"
         ("multipart/form-data; boundary=" ^ boundary)
  in
  H.Request.make ~headers ~body:(H.Request.Fixed [ body ]) "POST"
    (join_url provider.base_url path)

let chat_completions ?structured_output ?provider:custom_provider client ~api_key
    request =
  let provider =
    Option.value ~default:(chat_completions_provider ()) custom_provider
  in
  match chat_completions_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider request (perform_chat provider client http_request)

let responses ?structured_output ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match responses_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider request (perform_chat provider client http_request)

let stream_chat_completions ?structured_output ?provider:custom_provider client
    ~api_key request =
  let provider =
    Option.value ~default:(chat_completions_provider ()) custom_provider
  in
  let request = { request with A.stream = true } in
  match chat_completions_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_stream_span provider request
        (perform_stream provider client http_request)

let stream_responses ?structured_output ?provider:custom_provider client ~api_key
    request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  let request = { request with A.stream = true } in
  match responses_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_stream_span provider request
        (perform_stream provider client http_request)

let embeddings_request ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  A.embeddings_request provider ~api_key request

let embeddings ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match embeddings_request ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_embeddings_span provider request
        (perform_embeddings provider client http_request)

let image_generation_request ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match encode_image_generation request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok (A.provider_post_request provider ~path:"/v1/images/generations" api_key raw)

let image_generation ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match image_generation_request ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_raw provider client http_request
      |> E.bind (fun raw ->
             match decode_image_response raw with
             | Stdlib.Ok response -> E.pure response
             | Stdlib.Error error -> E.fail error)

let speech_request ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match encode_speech request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok (A.provider_post_request provider ~path:"/v1/audio/speech" api_key raw)

let speech ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match speech_request ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_binary ~max_bytes:(64 * 1024 * 1024) provider client http_request
      |> E.map decode_speech_response

let transcription_request ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match multipart_transcription_body request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok (boundary, body) ->
      Stdlib.Ok
        (multipart_request provider ~path:"/v1/audio/transcriptions" api_key
           boundary body)

let transcription ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match transcription_request ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_raw provider client http_request
      |> E.bind (fun raw ->
             match decode_transcription_response raw with
             | Stdlib.Ok response -> E.pure response
             | Stdlib.Error error -> E.fail error)

module Chat = struct
  include A.Provider.Chat

  let responses_request = responses_request
  let responses = responses
  let stream_responses = stream_responses
end

module Embeddings = struct
  include A.Provider.Embeddings
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
