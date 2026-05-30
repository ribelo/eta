(** Public OpenRouter provider surface. The public type and value signatures live
    in [eta_ai_openrouter.mli]. *)

module Responses_endpoint = Responses_impl
module Embeddings_endpoint = Embeddings_impl
module Speech_endpoint = Speech_impl
module Transcription_endpoint = Transcription_impl
module Rerank_endpoint = Rerank_impl
module Video_endpoint = Video_impl
module Images_endpoint = Images_impl

type attribution = Common.attribution = {
  referer : string option;
  title : string option;
}

let attribution = Common.attribution

type routing = Common.routing = {
  order : string list;
  only_providers : string list;
  ignored_providers : string list;
  allow_fallbacks : bool option;
  require_parameters : bool option;
  sort : string option;
}

let routing = Common.routing

type structured_output = Common.structured_output = {
  name : string;
  schema : Common.A.Json.t;
  strict : bool option;
}

let structured_output = Common.structured_output
let provider = Common.provider

let encode_responses = Common.encode_responses
let decode_responses = Common.decode_responses
let encode_embeddings = Common.encode_embeddings
let decode_embeddings = Common.decode_embeddings
let decode_stream_event = Common.decode_stream_event
let decode_error = Common.decode_error

let responses_request = Responses_endpoint.request
let responses = Responses_endpoint.run
let stream_responses = Responses_endpoint.stream

let embeddings_request = Embeddings_endpoint.request
let embeddings = Embeddings_endpoint.run

let encode_speech = Speech_endpoint.encode
let speech_request = Speech_endpoint.request
let speech = Speech_endpoint.run

let encode_transcription = Transcription_endpoint.encode
let decode_transcription = Transcription_endpoint.decode
let transcription_request = Transcription_endpoint.request
let transcription = Transcription_endpoint.run

let encode_rerank = Rerank_endpoint.encode
let decode_rerank = Rerank_endpoint.decode
let rerank_request = Rerank_endpoint.request
let rerank = Rerank_endpoint.run

let encode_video = Video_endpoint.encode
let decode_video = Video_endpoint.decode
let video_request = Video_endpoint.request
let video = Video_endpoint.run
let video_get_request = Video_endpoint.get_request
let video_get = Video_endpoint.get
let video_content_request = Video_endpoint.content_request
let video_content = Video_endpoint.content

let encode_image_generation = Images_endpoint.encode
let decode_image_generation = Images_endpoint.decode
let image_generation_request = Images_endpoint.request
let image_generation = Images_endpoint.run

module Chat = struct
  include Common.A.Provider.Chat

  let encode_responses = Common.encode_responses
  let responses_request = Responses_endpoint.request
  let responses = Responses_endpoint.run
  let stream_responses = Responses_endpoint.stream
end

module Embeddings = struct
  include Common.A.Provider.Embeddings

  let encode_with_routing = Common.encode_embeddings
  let request_with_routing = Embeddings_endpoint.request
  let run_with_routing = Embeddings_endpoint.run
end

module Speech = struct
  let create ~provider client ~api_key request =
    Speech_endpoint.run ~provider client ~api_key request
end

module Images = struct
  let generate ~provider client ~api_key request =
    Images_endpoint.run ~provider client ~api_key request
end

module Transcriptions = struct
  let create ~provider client ~api_key request =
    Transcription_endpoint.run ~provider client ~api_key request
end

module Rerank = struct
  let run ~provider client ~api_key request =
    Rerank_endpoint.run ~provider client ~api_key request
end

module Video = struct
  let create ~provider client ~api_key request =
    Video_endpoint.run ~provider client ~api_key request

  let get ~provider client ~api_key ~job_id =
    Video_endpoint.get ~provider client ~api_key ~job_id

  let content ~provider client ~api_key request =
    Video_endpoint.content ~provider client ~api_key request
end
