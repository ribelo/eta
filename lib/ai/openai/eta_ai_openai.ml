(** Public OpenAI provider surface — barrel that re-exports the decomposed
    implementation modules. The public type and value signatures live in
    [eta_ai_openai.mli]. *)

(* Shared infrastructure: types, JSON helpers, codec wrappers, providers. *)
include Common

(* ------------------------------------------------------------------ *)
(* Phase 1: top-level [let] re-exports.                                *)
(* These reference the file-level modules ([Responses], [Images], …)   *)
(* and must precede the [module Images = struct … end] re-bindings     *)
(* below, because those re-bindings shadow the file-level names.       *)
(* ------------------------------------------------------------------ *)

(* Chat / Responses surface. *)
let chat_completions_request = Chat_completions.request
let responses_request = Responses.request
let chat_completions = Chat_completions.run
let responses = Responses.run
let stream_chat_completions = Chat_completions.stream
let stream_responses = Responses.stream

(* Embeddings surface. *)
let embeddings_request = Embeddings.request
let embeddings = Embeddings.run

(* Images surface. *)
let encode_image_generation = Images.encode
let decode_image_response = Images.decode
let image_generation_request = Images.request
let image_generation = Images.run

(* Speech surface. *)
let encode_speech = Speech.encode
let speech_request = Speech.request
let speech = Speech.run

(* Transcriptions surface. *)
let decode_transcription_response = Transcriptions.decode_response
let transcription_request = Transcriptions.request
let transcription = Transcriptions.run

(* ------------------------------------------------------------------ *)
(* Phase 2: nested submodule re-bindings ([Eta_ai_openai.Chat], etc.). *)
(* The [.mli] restricts each one to its [Eta_ai.Provider.*] interface. *)
(* ------------------------------------------------------------------ *)

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
    Images.run ~provider client ~api_key request
end

module Speech = struct
  let create ~provider client ~api_key request =
    Speech.run ~provider client ~api_key request
end

module Transcriptions = struct
  let create ~provider client ~api_key request =
    Transcriptions.run ~provider client ~api_key request
end
