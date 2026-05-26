module A = Ai
module E = Eta.Effect
module Common = Common

type structured_output = Common.structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let structured_output = Common.structured_output
let encode_chat = Chat.encode
let encode_responses = Responses.encode
let decode_chat = Chat.decode
let decode_responses = Responses.decode
let decode_stream_event = Stream_codec.decode_event
let decode_error = Common.decode_error
module Realtime = Realtime

let auth_headers api_key =
  Http.Core.Header.unsafe_of_list
    [
      ("Authorization", "Bearer " ^ Redacted.value api_key);
      ("Content-Type", "application/json");
      ("Accept", "application/json");
    ]

let capabilities =
  {
    A.streaming = true;
    tools = true;
    tool_choice = true;
    structured_outputs = true;
  }

let chat_completions_provider ?(base_url = "https://api.openai.com") () =
  {
    A.name = "openai";
    base_url;
    chat_path = "/v1/chat/completions";
    auth_headers;
    capabilities;
    encode_chat;
    decode_chat;
    decode_stream_event;
    decode_error;
  }

let responses_provider ?(base_url = "https://api.openai.com") () =
  {
    A.name = "openai";
    base_url;
    chat_path = "/v1/responses";
    auth_headers;
    capabilities;
    encode_chat = encode_responses;
    decode_chat = decode_responses;
    decode_stream_event;
    decode_error;
  }

let provider ?base_url () = responses_provider ?base_url ()

let make_request = A.provider_request

let chat_completions_request ?structured_output ?provider:custom_provider ~api_key
    request =
  let provider =
    Option.value ~default:(chat_completions_provider ()) custom_provider
  in
  let encoded =
    match structured_output with
    | None -> provider.A.encode_chat request
    | Some _ -> encode_chat ?structured_output request
  in
  match encoded with
  | Stdlib.Ok raw -> Stdlib.Ok (make_request provider api_key raw)
  | Stdlib.Error _ as error -> error

let responses_request ?structured_output ?provider:custom_provider ~api_key
    request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  let encoded =
    match structured_output with
    | None -> provider.A.encode_chat request
    | Some _ -> encode_responses ?structured_output request
  in
  match encoded with
  | Stdlib.Ok raw -> Stdlib.Ok (make_request provider api_key raw)
  | Stdlib.Error _ as error -> error

let perform_chat = A.perform_chat
let perform_stream = A.perform_stream

let chat_completions ?structured_output ?provider:custom_provider client ~api_key
    request =
  let provider =
    Option.value ~default:(chat_completions_provider ()) custom_provider
  in
  match chat_completions_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider request (perform_chat provider client http_request)

let responses ?structured_output ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  match responses_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider request (perform_chat provider client http_request)

let stream_chat_completions ?structured_output ?provider:custom_provider client
    ~api_key request =
  let provider =
    Option.value ~default:(chat_completions_provider ()) custom_provider
  in
  let request = { request with A.stream = true } in
  match chat_completions_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_stream_span provider request
        (perform_stream provider client http_request)

let stream_responses ?structured_output ?provider:custom_provider client ~api_key
    request =
  let provider = Option.value ~default:(provider ()) custom_provider in
  let request = { request with A.stream = true } in
  match responses_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_stream_span provider request
        (perform_stream provider client http_request)
