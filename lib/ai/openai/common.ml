(** Shared OpenAI provider plumbing: types, JSON helpers, codec wrappers, and
    provider builders. Endpoint modules ([Chat], [Embeddings], etc.) layer
    request builders and runners on top of this. *)

module A = Eta_ai
module Codec = Eta_ai_openai_codec
module E = Eta.Effect
module H = Eta_http
module Json = A.Json

type structured_output = Codec.structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let schema_value = Codec.schema_value ~provider:"openai"

let structured_output ?strict ~name ~schema_json () =
  Codec.structured_output ~schema_value ?strict ~name ~schema_json ()

let encode_chat ?structured_output request =
  Codec.encode_chat ~provider:"openai" ~schema_value ?structured_output request

let encode_responses ?structured_output request =
  Codec.encode_responses ~provider:"openai" ~schema_value ?structured_output
    request

let decode_chat raw = Codec.decode_chat ~provider:"openai" raw
let decode_responses raw = Codec.decode_responses ~provider:"openai" raw

let decode_stream_event event =
  Codec.decode_stream_event ~provider:"openai" event

let decode_error ~status ~headers raw =
  Codec.decode_error ~provider:"openai" ~status ~headers raw

let decode_error_result ?raw message =
  Codec.decode_error_result ?raw ~provider:"openai" message

let parse_json raw = Codec.parse_json ~provider:"openai" raw

let unsupported feature =
  Stdlib.Error (A.Unsupported { provider = "openai"; feature })

let encode_embeddings = Codec.encode_embeddings ~provider:"openai"
let decode_embeddings raw = Codec.decode_embeddings ~provider:"openai" raw

let auth_headers api_key =
  Eta_http.Core.Header.unsafe_of_list
    [
      ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
      ("Content-Type", "application/json");
      ("Accept", "application/json");
    ]

let capabilities =
  {
    A.streaming = true;
    tools = true;
    tool_choice = true;
    structured_outputs = true;
    text = true;
    image_input = true;
    audio_input = true;
    video_input = false;
    embeddings = true;
    image_generation = true;
    speech = true;
    transcription = true;
    rerank = false;
    video_generation = false;
  }

let chat_completions_provider ?(base_url = "https://api.openai.com") () =
  {
    A.name = "openai";
    base_url;
    chat_path = "/v1/chat/completions";
    embeddings_path = Some "/v1/embeddings";
    auth_headers;
    capabilities;
    encode_chat;
    decode_chat;
    encode_embeddings;
    decode_embeddings;
    decode_stream_event;
    decode_error;
  }

let responses_provider ?(base_url = "https://api.openai.com") () =
  {
    A.name = "openai";
    base_url;
    chat_path = "/v1/responses";
    embeddings_path = Some "/v1/embeddings";
    auth_headers;
    capabilities;
    encode_chat = encode_responses;
    decode_chat = decode_responses;
    encode_embeddings;
    decode_embeddings;
    decode_stream_event;
    decode_error;
  }

let provider ?base_url () = responses_provider ?base_url ()

let make_request = A.provider_request
let perform_chat = A.perform_chat
let perform_stream = A.perform_stream
let perform_embeddings = A.perform_embeddings

let join_url base path =
  let base =
    if String.ends_with ~suffix:"/" base then
      String.sub base 0 (String.length base - 1)
    else base
  in
  let path = if String.starts_with ~prefix:"/" path then path else "/" ^ path in
  base ^ path

let with_json_fields extra fields =
  Json.object_ (fields @ List.map (fun (name, value) -> (name, Some value)) extra)
