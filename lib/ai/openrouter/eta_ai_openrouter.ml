(** OpenRouter facade preserving endpoint-oriented public names over shared
    provider implementations. *)

include Common

type credential = A.api_key

let credential = A.api_key
let authorization_headers = auth_headers
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

(** Native model catalog ([GET /api/v1/models]). *)

let models_catalog_max_bytes = 5 * 1024 * 1024

type pricing = {
  prompt : float option;
  completion : float option;
  input_cache_read : float option;
  input_cache_write : float option;
  request : float option;
}

type model_info = {
  id : string;
  name : string option;
  context_length : int option;
  pricing : pricing option;
}

let openrouter_id_prefix = "openrouter/"

let normalize_model_id id =
  let trimmed = String.trim id in
  let prefix_len = String.length openrouter_id_prefix in
  if
    String.length trimmed >= prefix_len
    && String.sub trimmed 0 prefix_len = openrouter_id_prefix
  then String.sub trimmed prefix_len (String.length trimmed - prefix_len)
  else trimmed

let non_negative_finite_float value =
  if Float.is_finite value && value >= 0. then Some value else None

let float_of_json = function
  | `String s -> (
      match String.trim s with
      | "" -> None
      | trimmed ->
          Option.bind (float_of_string_opt trimmed) non_negative_finite_float)
  | `Float f -> non_negative_finite_float f
  | `Int i when i >= 0 -> Some (float_of_int i)
  | `Intlit s -> Option.bind (float_of_string_opt s) non_negative_finite_float
  | `Null | `Bool _ | `Assoc _ | `List _ | `Tuple _ | `Variant _ | `Int _ ->
      None

let int_of_json = function
  | `Int i when i >= 0 -> Some i
  | `Intlit s -> (
      match int_of_string_opt s with
      | Some value when value >= 0 -> Some value
      | Some _ | None -> None)
  | `Float f when Float.is_integer f && f >= 0. && f <= float_of_int max_int ->
      Some (int_of_float f)
  | `String s -> (
      match String.trim s with
      | "" -> None
      | trimmed -> (
          match int_of_string_opt trimmed with
          | Some value when value >= 0 -> Some value
          | Some _ | None -> None))
  | `Null | `Bool _ | `Assoc _ | `List _ | `Tuple _ | `Variant _ | `Float _
  | `Int _ ->
      None

let pricing_of_json json =
  let price key =
    match Json.member key json with
    | None -> None
    | Some value -> float_of_json value
  in
  let pricing =
    {
      prompt = price "prompt";
      completion = price "completion";
      input_cache_read = price "input_cache_read";
      input_cache_write = price "input_cache_write";
      request = price "request";
    }
  in
  if
    pricing.prompt = None && pricing.completion = None
    && pricing.input_cache_read = None
    && pricing.input_cache_write = None
    && pricing.request = None
  then None
  else Some pricing

let context_length_of_entry entry =
  let nested_top_provider () =
    match Json.object_member "top_provider" entry with
    | None -> None
    | Some top -> (
        match Json.member "context_length" top with
        | Some value -> int_of_json value
        | None -> None)
  in
  match Json.member "context_length" entry with
  | Some value -> (
      match int_of_json value with
      | Some _ as length -> length
      | None -> nested_top_provider ())
  | None -> nested_top_provider ()

let model_info_of_json json =
  match Json.string_member "id" json with
  | None -> None
  | Some id ->
      let id = normalize_model_id id in
      if id = "" then None
      else
        let name =
          match Json.string_member "name" json with
          | Some name when String.trim name <> "" -> Some (String.trim name)
          | Some _ | None -> None
        in
        let pricing =
          match Json.object_member "pricing" json with
          | Some pricing_json -> pricing_of_json pricing_json
          | None -> None
        in
        Some
          { id; name; context_length = context_length_of_entry json; pricing }

let decode_models raw =
  match Json.parse raw with
  | Stdlib.Error message -> decode_error_result message
  | Stdlib.Ok json -> (
      match Json.array_member "data" json with
      | None -> decode_error_result "expected a top-level data array"
      | Some items ->
          (* Empty catalogs are valid wire results; callers decide refresh policy. *)
          Stdlib.Ok (List.filter_map model_info_of_json items))

let models_request ?provider:custom_provider ~api_key () =
  let provider = default_provider provider custom_provider in
  Stdlib.Ok (A.provider_get_request provider ~path:"/api/v1/models" api_key)

let list_models ?provider:custom_provider client ~api_key =
  let provider = default_provider provider custom_provider in
  match models_request ~provider ~api_key () with
  | Stdlib.Error error -> Eta.Effect.fail error
  | Stdlib.Ok request ->
      A.run_raw_decoded ~max_bytes:models_catalog_max_bytes provider client
        (Stdlib.Ok request) decode_models
