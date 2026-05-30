(** Public OpenRouter provider surface — barrel that re-exports the decomposed
    implementation modules. The public type and value signatures live in
    [eta_ai_openrouter.mli]. *)

(* Shared infrastructure: types, JSON helpers, codec wrappers, attribution,
   routing, and the provider builder. *)
include Common

(* Responses surface (OpenRouter's only chat-style API). *)
let responses_request = Responses_impl.request
let responses = Responses_impl.run
let stream_responses = Responses_impl.stream

(* Embeddings surface. *)
let embeddings_request = Embeddings_impl.request
let embeddings = Embeddings_impl.run

(* Speech surface. *)
let encode_speech = Speech_impl.encode
let speech_request = Speech_impl.request
let speech = Speech_impl.run

(* Transcription surface. *)
let encode_transcription = Transcription_impl.encode
let decode_transcription = Transcription_impl.decode
let transcription_request = Transcription_impl.request
let transcription = Transcription_impl.run

(* Rerank surface. *)
let encode_rerank = Rerank_impl.encode
let decode_rerank = Rerank_impl.decode
let rerank_request = Rerank_impl.request
let rerank = Rerank_impl.run

(* Video surface. *)
let encode_video = Video_impl.encode
let decode_video = Video_impl.decode
let video_request = Video_impl.request
let video = Video_impl.run
let video_get_request = Video_impl.get_request
let video_get = Video_impl.get
let video_content_request = Video_impl.content_request
let video_content = Video_impl.content

(* Images surface. *)
let encode_image_generation = Images_impl.encode
let decode_image_generation = Images_impl.decode
let image_generation_request = Images_impl.request
let image_generation = Images_impl.run

module Chat = struct
  include Common.A.Provider.Chat

  let encode_responses = Common.encode_responses
  let responses_request = Responses_impl.request
  let responses = Responses_impl.run
  let stream_responses = Responses_impl.stream
end

module Embeddings = struct
  include Common.A.Provider.Embeddings

  let encode_with_routing = Common.encode_embeddings
  let request_with_routing = Embeddings_impl.request
  let run_with_routing = Embeddings_impl.run
end

module Speech = struct
  let create = Speech_impl.create
end

module Images = struct
  let generate = Images_impl.generate
end

module Transcriptions = struct
  let create = Transcription_impl.create
end

module Rerank = struct
  let run = Rerank_impl.run_with_provider
end

module Video = struct
  let create = Video_impl.create

  let get = Video_impl.get_with_provider

  let content = Video_impl.content_with_provider
end
