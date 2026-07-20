(** OpenAI facade preserving endpoint-oriented public names over shared provider
    implementations. *)

include Common

type credential = A.api_key

let credential = A.api_key
let authorization_headers = auth_headers

module Image_endpoint = Images
module Speech_endpoint = Speech
module Transcription_endpoint = Transcriptions

let chat_completions_request = Chat_completions.request
let responses_request = Responses.request
let chat_completions = Chat_completions.run
let responses = Responses.run
let stream_chat_completions = Chat_completions.stream
let stream_responses = Responses.stream

let embeddings_request ?provider:custom_provider ~api_key embedding_request =
  let provider = default_provider provider custom_provider in
  A.Provider.Embeddings.request ~provider ~api_key embedding_request

let embeddings ?provider:custom_provider client ~api_key embedding_request =
  let provider = default_provider provider custom_provider in
  A.Provider.Embeddings.run ~provider client ~api_key embedding_request

let encode_image_generation = Image_endpoint.encode
let decode_image_response = Image_endpoint.decode
let image_generation_request = Image_endpoint.request
let image_generation = Image_endpoint.run

let encode_speech = Speech_endpoint.encode
let speech_request = Speech_endpoint.request
let speech = Speech_endpoint.run

let decode_transcription_response = Transcription_endpoint.decode_response
let transcription_request = Transcription_endpoint.request
let transcription = Transcription_endpoint.run

module Realtime = Realtime

module Chat = struct
  include A.Provider.Chat

  let responses_request = Responses.request
  let responses = Responses.run
  let stream_responses = Responses.stream
end

module Embeddings = A.Provider.Embeddings

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
  | Stdlib.Error message -> decode_error_result message
  | Stdlib.Ok json -> (
      match Json.array_member "data" json with
      | None -> decode_error_result "expected a top-level data array"
      | Some items ->
          let models = List.filter_map model_info_of_json items in
          if models = [] then decode_error_result "models catalog is empty"
          else Stdlib.Ok models)

let models_request ?provider:custom_provider ~api_key () =
  let provider = default_provider provider custom_provider in
  Stdlib.Ok (A.provider_get_request provider ~path:"/v1/models" api_key)

let list_models ?provider:custom_provider client ~api_key =
  let provider = default_provider provider custom_provider in
  match models_request ~provider ~api_key () with
  | Stdlib.Error error -> Eta.Effect.fail error
  | Stdlib.Ok request ->
      A.run_raw_decoded ~max_bytes:models_catalog_max_bytes provider client
        (Stdlib.Ok request) decode_models
