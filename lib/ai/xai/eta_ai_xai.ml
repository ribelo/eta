module A = Eta_ai
module C = Common

let provider_name = C.provider_name
let default_base_url = C.default_base_url
let default_management_base_url = C.default_management_base_url

type credential = A.api_key
let credential = A.api_key
let api_key value = value
let authorization_headers = C.inference_headers

let decode_error = Xai_error.decode

let decode_neutral_response raw =
  Responses.decode_response raw
  |> Result.map Responses.to_eta_ai_response
  |> Result.map_error Xai_error.to_ai_error

let decode_neutral_stream event =
  Responses.decode_stream_event event
  |> Result.map Responses.to_eta_ai_stream_events
  |> Result.map_error Xai_error.to_ai_error

let unsupported feature =
  Error (A.Unsupported { provider = provider_name; feature })

let provider ?(endpoint = Endpoint.default_inference) () =
  let base_url = Endpoint.inference_base_url endpoint in
  {
    A.name = provider_name;
    base_url;
    chat_path = "/v1/responses";
    embeddings_path = None;
    auth_headers = C.inference_headers;
    capabilities = Capabilities.shared;
    encode_chat =
      (fun _ ->
        unsupported
          "Chat Completions is outside the xAI provider Responses surface");
    decode_chat = decode_neutral_response;
    encode_embeddings = (fun _ -> unsupported "embeddings");
    decode_embeddings = (fun _ -> unsupported "embeddings");
    decode_stream_event = decode_neutral_stream;
    decode_error =
      (fun ~status ~headers raw ->
        Xai_error.decode ~status ~headers raw |> Xai_error.to_ai_error);
  }

let responses_provider ?endpoint () =
  let transport = provider ?endpoint () in
  {
    A.transport;
    encode_responses =
      (fun request ->
        Responses.of_eta_ai request
        |> (fun result -> Result.bind result Responses.encode_request)
        |> Result.map_error Xai_error.to_ai_error);
  }

module Error = Xai_error
module Endpoint = Endpoint
module Capabilities = Capabilities
module Responses = Responses
module Files = Files
module Collections = Collections
module Models = Models

module Audio = struct
  module Speech_to_text = Speech_to_text
  module Text_to_speech = Text_to_speech
  module Voices = Voices
  module Realtime = Realtime
end
