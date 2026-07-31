(** OpenAI facade preserving endpoint-oriented public names over shared provider
    implementations. *)

include Common

module Error = Openai_error

type stream = Common.stream

type credential = A.api_key

let credential = A.api_key
let authorization_headers = auth_headers

module Image_endpoint = Images

let chat_completions_request = Chat_completions.request
let responses_request = Responses.request
let chat_completions = Chat_completions.run
let responses = Responses.run
let stream_chat_completions = Chat_completions.stream
let stream_responses = Responses.stream

let stream_of_body = Common.stream_of_body
let read_stream_event = Common.read_stream_event
let read_stream_events = Common.read_stream_events
let close_stream = Common.close_stream

let embeddings_request ?provider:custom_provider ~api_key embedding_request =
  let provider = default_provider provider custom_provider in
  match provider.A.encode_embeddings embedding_request |> of_neutral_result with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw -> (
      match provider.embeddings_path with
      | None -> unsupported "embeddings"
      | Some path ->
          Stdlib.Ok
            (H.Request.make ~headers:(provider.auth_headers api_key)
               ~body:(H.Request.Fixed [ Bytes.of_string raw ])
               "POST"
               (join_url provider.base_url path)))

let embeddings ?provider:custom_provider client ~api_key embedding_request =
  let provider = default_provider provider custom_provider in
  embeddings_request ~provider ~api_key embedding_request
  |> run_embeddings provider client embedding_request

let encode_image_generation = Image_endpoint.encode
let decode_image_response = Image_endpoint.decode
let image_generation_request = Image_endpoint.request
let image_generation = Image_endpoint.run

module Audio = struct
  module Voices = Speech.Voices

  module Speech_to_text = Transcriptions
  module Text_to_speech = Speech
  module Realtime = Realtime
end

module Chat = struct
  let encode ~provider request =
    provider.A.encode_chat request |> of_neutral_result

  let decode ~provider raw =
    provider.A.decode_chat raw |> of_neutral_result

  let request ~provider ~api_key chat_request =
    match encode ~provider chat_request with
    | Stdlib.Error _ as error -> error
    | Stdlib.Ok raw ->
        Stdlib.Ok
          (H.Request.make ~headers:(provider.A.auth_headers api_key)
             ~body:(H.Request.Fixed [ Bytes.of_string raw ])
             "POST"
             (join_url provider.base_url provider.chat_path))

  let run ~provider client ~api_key chat_request =
    request ~provider ~api_key chat_request
    |> run_chat provider client chat_request

  let stream ~provider client ~api_key chat_request =
    let chat_request = { chat_request with A.stream = true } in
    request ~provider ~api_key chat_request
    |> run_stream provider client chat_request

  let responses_request = Responses.request
  let responses = Responses.run
  let stream_responses = Responses.stream
end

module Embeddings = struct
  let encode ~provider request =
    provider.A.encode_embeddings request |> of_neutral_result

  let decode ~provider raw =
    provider.A.decode_embeddings raw |> of_neutral_result

  let request ~provider ~api_key embedding_request =
    embeddings_request ~provider ~api_key embedding_request

  let run ~provider client ~api_key embedding_request =
    embeddings ~provider client ~api_key embedding_request
end

module Images = struct
  let generate ~provider client ~api_key request =
    image_generation ~provider client ~api_key request
end

(** Native model catalog ([GET /v1/models]). *)

let models_catalog_max_bytes = 5 * 1024 * 1024

type model_info = { id : string }

let model_info_of_json json =
  match Json.string_member "id" json with
  | None -> None
  | Some id ->
      let id = String.trim id in
      if id = "" then None else Some { id }

let decode_models raw =
  match Json.parse raw with
  | Stdlib.Error message -> decode_error_result ~raw message
  | Stdlib.Ok json -> (
      match Json.array_member "data" json with
      | None -> decode_error_result ~raw "expected a top-level data array"
      | Some items -> Stdlib.Ok (List.filter_map model_info_of_json items))

let models_request ?provider:custom_provider ~api_key () =
  let provider = default_provider provider custom_provider in
  Stdlib.Ok
    (H.Request.make ~headers:(provider.A.auth_headers api_key) "GET"
       (join_url provider.base_url "/v1/models"))

let list_models ?provider:custom_provider client ~api_key =
  let provider = default_provider provider custom_provider in
  match models_request ~provider ~api_key () with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok request ->
      run_raw_decoded ~max_bytes:models_catalog_max_bytes provider client
        (Stdlib.Ok request) decode_models
