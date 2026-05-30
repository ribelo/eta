(** Public OpenAI provider surface. The public type and value signatures live in
    [eta_ai_openai.mli]. *)

module Chat_completions_endpoint = Chat_completions
module Responses_endpoint = Responses
module Embeddings_endpoint = Embeddings
module Images_endpoint = Images
module Speech_endpoint = Speech
module Transcriptions_endpoint = Transcriptions

type structured_output = Common.structured_output = {
  name : string;
  schema : Common.A.Json.t;
  strict : bool option;
}

let structured_output = Common.structured_output
let provider = Common.provider
let chat_completions_provider = Common.chat_completions_provider
let responses_provider = Common.responses_provider

let encode_chat = Common.encode_chat
let encode_responses = Common.encode_responses
let decode_chat = Common.decode_chat
let decode_responses = Common.decode_responses
let encode_embeddings = Common.encode_embeddings
let decode_embeddings = Common.decode_embeddings
let decode_stream_event = Common.decode_stream_event
let decode_error = Common.decode_error

let chat_completions_request = Chat_completions_endpoint.request
let responses_request = Responses_endpoint.request
let chat_completions = Chat_completions_endpoint.run
let responses = Responses_endpoint.run
let stream_chat_completions = Chat_completions_endpoint.stream
let stream_responses = Responses_endpoint.stream

let embeddings_request = Embeddings_endpoint.request
let embeddings = Embeddings_endpoint.run

let encode_image_generation = Images_endpoint.encode
let decode_image_response = Images_endpoint.decode
let image_generation_request = Images_endpoint.request
let image_generation = Images_endpoint.run

let encode_speech = Speech_endpoint.encode
let speech_request = Speech_endpoint.request
let speech = Speech_endpoint.run

let decode_transcription_response = Transcriptions_endpoint.decode_response
let transcription_request = Transcriptions_endpoint.request
let transcription = Transcriptions_endpoint.run

module Realtime = Realtime

module Chat = struct
  include Common.A.Provider.Chat

  let responses_request = Responses_endpoint.request
  let responses = Responses_endpoint.run
  let stream_responses = Responses_endpoint.stream
end

module Embeddings = struct
  include Common.A.Provider.Embeddings
end

module Images = struct
  let generate ~provider client ~api_key request =
    Images_endpoint.run ~provider client ~api_key request
end

module Speech = struct
  let create ~provider client ~api_key request =
    Speech_endpoint.run ~provider client ~api_key request
end

module Transcriptions = struct
  let create ~provider client ~api_key request =
    Transcriptions_endpoint.run ~provider client ~api_key request
end
