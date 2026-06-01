(** OpenRouter facade preserving endpoint-oriented public names over shared
    provider implementations. *)

include Common

let responses_request = Responses_impl.request
let responses = Responses_impl.run
let stream_responses = Responses_impl.stream

let embeddings_request = Embeddings_impl.request
let embeddings = Embeddings_impl.run

let encode_speech = Speech_impl.encode
let speech_request = Speech_impl.request
let speech = Speech_impl.run

let encode_transcription = Transcription_impl.encode
let decode_transcription = Transcription_impl.decode
let transcription_request = Transcription_impl.request
let transcription = Transcription_impl.run

let encode_rerank = Rerank_impl.encode
let decode_rerank = Rerank_impl.decode
let rerank_request = Rerank_impl.request
let rerank = Rerank_impl.run

let encode_video = Video_impl.encode
let decode_video = Video_impl.decode
let video_request = Video_impl.request
let video = Video_impl.run
let video_get_request = Video_impl.get_request
let video_get = Video_impl.get
let video_content_request = Video_impl.content_request
let video_content = Video_impl.content

let encode_image_generation = Images_impl.encode
let decode_image_generation = Images_impl.decode
let image_generation_request = Images_impl.request
let image_generation = Images_impl.run

module Chat = struct
  include A.Provider.Chat

  let encode_responses = encode_responses
  let responses_request = Responses_impl.request
  let responses = Responses_impl.run
  let stream_responses = Responses_impl.stream
end

module Embeddings = struct
  include A.Provider.Embeddings

  let encode_with_routing = encode_embeddings
  let request_with_routing = Embeddings_impl.request
  let run_with_routing = Embeddings_impl.run
end

module Speech = struct
  let create ~provider client ~api_key request =
    speech ~provider client ~api_key request
end

module Images = struct
  let generate ~provider client ~api_key request =
    image_generation ~provider client ~api_key request
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
