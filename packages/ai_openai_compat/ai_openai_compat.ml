module A = Ai
module Codec = Ai_openai_codec
module E = Eta.Effect
module H = Http

type auth = {
  header : string;
  prefix : string option;
}

type structured_output = Codec.structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let decode_error_result ?raw message =
  Codec.decode_error_result ?raw ~provider:"openai-compatible" message

let parse_json raw = Codec.parse_json ~provider:"openai-compatible" raw

let require_json label raw =
  Codec.schema_value ~provider:"openai-compatible" label raw

let structured_output ?strict ~name ~schema_json () =
  Codec.structured_output ~schema_value:require_json ?strict ~name ~schema_json
    ()

let bearer_auth ?(header = "Authorization") () =
  { header; prefix = Some "Bearer " }

let raw_header_auth ~header () = { header; prefix = None }

let auth_value auth api_key =
  Option.value ~default:"" auth.prefix ^ Redacted.value api_key

let message_json = Codec.chat_message_json

let encode_chat ?structured_output request =
  Codec.encode_chat ~provider:"openai-compatible" ~schema_value:require_json
    ?structured_output request

let decode_chat raw =
  Codec.decode_chat ~usage_raw_prompt_names:true
    ~provider:"openai-compatible" raw

let provider_error ?status ?(provider = "openai-compatible") raw =
  Codec.provider_error ?status ~provider raw

let decode_error ~status ~headers raw =
  Codec.decode_error ~provider:"openai-compatible" ~status ~headers raw

let decode_stream_event event =
  Codec.decode_stream_event ~provider:"openai-compatible" event

let provider ?(name = "openai-compatible")
    ?(chat_path = "/v1/chat/completions") ?(auth = bearer_auth ())
    ?(extra_headers = []) ~base_url () =
  let auth_headers api_key =
    H.Core.Header.unsafe_of_list
      ([
         (auth.header, auth_value auth api_key);
         ("Content-Type", "application/json");
         ("Accept", "application/json");
       ]
      @ extra_headers)
  in
  {
    A.name;
    base_url;
    chat_path;
    auth_headers;
    capabilities =
      {
        A.streaming = true;
        tools = true;
        tool_choice = true;
        structured_outputs = true;
      };
    encode_chat = encode_chat;
    decode_chat;
    decode_stream_event;
    decode_error =
      (fun ~status ~headers raw ->
        match decode_error ~status ~headers raw with
        | A.Provider_error error -> A.Provider_error { error with provider = name }
        | error -> error);
  }

let make_request = A.provider_request

let chat_completions_request ?structured_output ~provider ~api_key request =
  match encode_chat ?structured_output request with
  | Stdlib.Ok raw -> Stdlib.Ok (make_request provider api_key raw)
  | Stdlib.Error _ as error -> error

let perform_chat = A.perform_chat
let perform_stream = A.perform_stream

let chat_completions ?structured_output ~provider client ~api_key request =
  match chat_completions_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider request (perform_chat provider client http_request)

let stream_chat_completions ?structured_output ~provider client ~api_key request =
  let request = { request with A.stream = true } in
  match chat_completions_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_stream_span provider request
        (perform_stream provider client http_request)
