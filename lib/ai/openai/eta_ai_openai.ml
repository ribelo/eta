(** Public OpenAI provider surface. The public type and value signatures live in
    [eta_ai_openai.mli]. *)

include Common

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
