(** Shared OpenAI provider plumbing: types, JSON helpers, codec wrappers, and
    provider builders. Endpoint modules ([Chat], [Embeddings], etc.) layer
    request builders and runners on top of this. *)

module A = Eta_ai
module Codec = Eta_ai_openai_codec
module H = Eta_http
module Json = A.Json

let ( let* ) = Result.bind

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

let encode_responses_tool =
  Codec.tool_json ~schema_value ~shape:Codec.Responses_tool

let reject_responses_field field = function
  | None -> Stdlib.Ok ()
  | Some _ ->
      Stdlib.Error (A.Unsupported { provider = "openai"; feature = field })

let normalize_responses_reasoning request =
  match request.A.Responses.reasoning with
  | None -> Stdlib.Ok request
  | Some reasoning -> (
      match reasoning.effort with
      | None -> Stdlib.Ok request
      | Some effort ->
          Codec.reasoning_level_of_string ~provider:"openai" effort
          |> Result.map (fun level ->
                 let effort =
                   match level with
                   | Codec.Off -> "none"
                   | _ -> Codec.reasoning_level_to_string level
                 in
                 {
                   request with
                   A.Responses.reasoning =
                     Some { reasoning with effort = Some effort };
                 }))

let encode_responses request =
  let* () = reject_responses_field "max_turns" request.A.Responses.max_turns in
  let* () = reject_responses_field "top_k" request.top_k in
  let* () = reject_responses_field "min_p" request.min_p in
  let* () = reject_responses_field "reasoning_effort" request.reasoning_effort in
  let* () =
    reject_responses_field "reasoning.generate_summary"
      (Option.bind request.reasoning (fun reasoning ->
           reasoning.generate_summary))
  in
  let* request = normalize_responses_reasoning request in
  Codec.encode_responses ~provider:"openai"
    ~encode_tool:encode_responses_tool request

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
    audio_input = false;
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

let responses_transport_provider ?(base_url = "https://api.openai.com") () =
  {
    A.name = "openai";
    base_url;
    chat_path = "/v1/responses";
    embeddings_path = Some "/v1/embeddings";
    auth_headers;
    capabilities;
    encode_chat =
      (fun _ ->
        unsupported
          "Chat Completions request cannot be sent to the Responses endpoint");
    decode_chat = decode_responses;
    encode_embeddings;
    decode_embeddings;
    decode_stream_event;
    decode_error;
  }

let provider ?base_url () = responses_transport_provider ?base_url ()

let responses_provider ?base_url () =
  {
    A.transport = responses_transport_provider ?base_url ();
    encode_responses;
  }

let default_provider default custom_provider =
  match custom_provider with
  | Some provider -> provider
  | None -> default ()

let post_request = A.post_request
let raw_chat_request = A.chat_request_from_raw

let run_chat = A.run_chat_request
let run_stream = A.run_stream_request
let run_responses = A.run_responses_request
let run_responses_stream = A.run_responses_stream_request
let run_raw_decoded = A.run_raw_decoded
let run_binary = A.run_binary_decoded

let join_url = A.join_url

let with_json_fields = Codec.with_json_fields
