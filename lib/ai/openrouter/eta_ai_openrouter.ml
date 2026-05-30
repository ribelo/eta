(** Public OpenRouter provider surface — barrel that re-exports the decomposed
    implementation modules. The public type and value signatures live in
    [eta_ai_openrouter.mli]. *)

(* Shared infrastructure: types, JSON helpers, codec wrappers, attribution,
   routing, and the provider builder. *)
include Common

(* ------------------------------------------------------------------ *)
(* Phase 1: top-level [let] re-exports.                                *)
(* These reference the file-level modules ([Responses], [Video], …)    *)
(* and must precede the [module …] re-bindings below, because those    *)
(* re-bindings shadow the file-level names.                            *)
(* ------------------------------------------------------------------ *)

(* Responses surface (OpenRouter's only chat-style API). *)
let responses_request = Responses.request
let responses = Responses.run
let stream_responses = Responses.stream

(* Embeddings surface. *)
let embeddings_request = Embeddings.request
let embeddings = Embeddings.run

(* Speech surface. *)
let encode_speech = Speech.encode
let speech_request = Speech.request
let speech = Speech.run

(* Transcription surface. *)
let encode_transcription = Transcription.encode
let decode_transcription = Transcription.decode
let transcription_request = Transcription.request
let transcription = Transcription.run

(* Rerank surface. *)
let encode_rerank = Rerank.encode
let decode_rerank = Rerank.decode
let rerank_request = Rerank.request
let rerank = Rerank.run

(* Video surface. *)
let encode_video = Video.encode
let decode_video = Video.decode
let video_request = Video.request
let video = Video.run
let video_get_request = Video.get_request
let video_get = Video.get
let video_content_request = Video.content_request
let video_content = Video.content

(* Images surface. *)
let encode_image_generation = Images.encode
let decode_image_generation = Images.decode
let image_generation_request = Images.request
let image_generation = Images.run

(* ------------------------------------------------------------------ *)
(* Phase 2: nested submodule re-bindings.                              *)
(* The [.mli] restricts each one to its [Eta_ai.Provider.*] interface, *)
(* with extras for [Chat] and [Embeddings].                            *)
(* ------------------------------------------------------------------ *)

module Chat = struct
  include Common.A.Provider.Chat

  let encode_responses = Common.encode_responses
  let responses_request = Responses.request
  let responses = Responses.run
  let stream_responses = Responses.stream
end

module Embeddings = struct
  include Common.A.Provider.Embeddings

  let encode_with_routing = Common.encode_embeddings
  let request_with_routing = Embeddings.request
  let run_with_routing = Embeddings.run
end

module Speech = struct
  let create ~provider client ~api_key request =
    Speech.run ~provider client ~api_key request
end

module Images = struct
  let generate ~provider client ~api_key request =
    Images.run ~provider client ~api_key request
end

module Transcriptions = struct
  let create ~provider client ~api_key request =
    Transcription.run ~provider client ~api_key request
end

module Rerank = struct
  let run ~provider client ~api_key request =
    Rerank.run ~provider client ~api_key request
end

module Video = struct
  let create ~provider client ~api_key request =
    Video.run ~provider client ~api_key request

  let get ~provider client ~api_key ~job_id =
    Video.get ~provider client ~api_key ~job_id

  let content ~provider client ~api_key request =
    Video.content ~provider client ~api_key request
end
