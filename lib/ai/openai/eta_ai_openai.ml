(** Public OpenAI provider surface. The public type and value signatures live in
    [eta_ai_openai.mli]. *)

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

let chat_completions_request = Chat_completions.request
let responses_request = Responses.request
let chat_completions = Chat_completions.run
let responses = Responses.run
let stream_chat_completions = Chat_completions.stream
let stream_responses = Responses.stream

let embeddings_request = Embeddings.request
let embeddings = Embeddings.run

let encode_image_generation = Images.encode
let decode_image_response = Images.decode
let image_generation_request = Images.request
let image_generation = Images.run

let encode_speech = Speech.encode
let speech_request = Speech.request
let speech = Speech.run

let decode_transcription_response = Transcriptions.decode_response
let transcription_request = Transcriptions.request
let transcription = Transcriptions.run

module Realtime = Realtime

module Chat = struct
  include Common.A.Provider.Chat

  let responses_request = Responses.request
  let responses = Responses.run
  let stream_responses = Responses.stream
end

module Embeddings = struct
  include Common.A.Provider.Embeddings
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
