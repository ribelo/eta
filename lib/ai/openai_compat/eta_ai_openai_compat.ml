module A = Eta_ai
module Codec = Eta_ai_openai_codec
module E = Eta.Effect
module Error = Compat_error
module H = Eta_http

type auth = {
  header : string;
  prefix : string option;
}

type structured_output = Codec.structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let default_provider_name = "openai-compatible"

let map_result ?(provider = default_provider_name) = function
  | Stdlib.Ok _ as ok -> ok
  | Stdlib.Error error -> Stdlib.Error (Error.of_ai_error ~provider error)

let of_neutral_result ?(provider = default_provider_name) = function
  | Stdlib.Ok _ as ok -> ok
  | Stdlib.Error error -> Stdlib.Error (Error.of_ai_error ~provider error)

let to_neutral_result = function
  | Stdlib.Ok _ as ok -> ok
  | Stdlib.Error error -> Stdlib.Error (Error.to_ai_error error)

let schema_value_lossless label raw =
  match A.Json.parse raw with
  | Stdlib.Ok json -> (Stdlib.Ok json : (_, Codec.codec_failure) result)
  | Stdlib.Error message ->
      let failure : Codec.codec_failure =
        Decode
          {
            message = Printf.sprintf "%s must be valid JSON: %s" label message;
            raw_body = Some raw;
          }
      in
      Stdlib.Error failure

let structured_output ?strict ~name ~schema_json () =
  match
    Codec.structured_output_lossless ~schema_value:schema_value_lossless ?strict
      ~name ~schema_json ()
  with
  | Stdlib.Ok value -> Stdlib.Ok value
  | Stdlib.Error failure ->
      Stdlib.Error
        (Error.of_codec_failure ~provider:default_provider_name failure)

let bearer_auth ?(header = "Authorization") () =
  { header; prefix = Some "Bearer " }

let raw_header_auth ~header () = { header; prefix = None }

let auth_value auth api_key =
  Option.value ~default:"" auth.prefix ^ Eta_redacted.value api_key

let encode_chat ?structured_output ?(provider = default_provider_name) request =
  match
    Codec.encode_chat_lossless ~schema_value:schema_value_lossless
      ?structured_output request
  with
  | Stdlib.Ok value -> Stdlib.Ok value
  | Stdlib.Error failure ->
      Stdlib.Error (Error.of_codec_failure ~provider failure)

let decode_chat ?(provider = default_provider_name) raw =
  Codec.decode_chat ~usage_raw_prompt_names:true ~provider raw
  |> map_result ~provider

let decode_error ~provider ~status ~headers raw =
  Error.decode ~provider ~status ~headers raw

let of_stream_failure ~provider = function
  | Codec.Decode { message; raw_body } ->
      Error.Decode { provider; message; raw_body }
  | Codec.Provider { payload; raw_body } ->
      Error.of_wire_payload ~provider ~raw_body payload

let decode_stream_event ?(provider = default_provider_name) event =
  match Codec.decode_stream_event_lossless ~provider event with
  | Stdlib.Ok events -> Stdlib.Ok events
  | Stdlib.Error failure -> Stdlib.Error (of_stream_failure ~provider failure)

let unsupported ~provider feature =
  Stdlib.Error (Error.Unsupported { provider; feature })

let unsupported_embeddings ~provider _request =
  unsupported ~provider "embeddings"

let decode_embeddings ~provider _raw = unsupported ~provider "embeddings"

let provider ?(name = default_provider_name)
    ?(chat_path = "/v1/chat/completions") ?(auth = bearer_auth ())
    ?(extra_headers = []) ~base_url () =
  let auth_headers api_key =
    H.Core.Header.unsafe_of_list
      ((auth.header, auth_value auth api_key)
      :: ("Content-Type", "application/json")
      :: ("Accept", "application/json") :: extra_headers)
  in
  {
    A.name;
    base_url;
    chat_path;
    embeddings_path = None;
    auth_headers;
    capabilities =
      {
        A.streaming = true;
        tools = true;
        tool_choice = true;
        structured_outputs = true;
        text = true;
        image_input = false;
        audio_input = false;
        video_input = false;
        embeddings = false;
        image_generation = false;
        speech = false;
        transcription = false;
        rerank = false;
        video_generation = false;
      };
    encode_chat =
      (fun request ->
        encode_chat ~provider:name request |> to_neutral_result);
    decode_chat =
      (fun raw -> decode_chat ~provider:name raw |> to_neutral_result);
    encode_embeddings =
      (fun request ->
        unsupported_embeddings ~provider:name request |> to_neutral_result);
    decode_embeddings =
      (fun raw -> decode_embeddings ~provider:name raw |> to_neutral_result);
    decode_stream_event =
      (fun event ->
        (* Neutral host path still embeds Stream_error. *)
        Codec.decode_stream_event ~provider:name event);
    decode_error =
      (fun ~status ~headers raw ->
        decode_error ~provider:name ~status ~headers raw |> Error.to_ai_error);
  }

let error_view : _ A.Provider.Telemetry.error_view =
  { error_type = Error.classification; error_pp = Error.pp }

let read_body ?max_bytes body =
  H.Body.Stream.read_all ?max_bytes body
  |> E.bind_error (fun error -> E.fail (Error.Http error))

let perform_decoded provider client request decode =
  H.request client request
  |> A.suppress_provider_transport_observability
  |> E.bind_error (fun error -> E.fail (Error.Http error))
  |> E.bind (fun (response : H.Response.t) ->
         if response.status >= 200 && response.status < 300 then
           read_body response.body
           |> E.bind (fun body ->
                  match decode (Bytes.to_string body) with
                  | Stdlib.Ok value -> E.pure value
                  | Stdlib.Error error -> E.fail error)
         else
           read_body response.body
           |> E.bind (fun body ->
                  E.fail
                    (decode_error ~provider:provider.A.name
                       ~status:response.status ~headers:response.headers
                       (Bytes.to_string body))))

type stream = {
  inner : A.stream;
  provider_name : string;
}

let perform_stream provider client request =
  H.request client request
  |> A.suppress_provider_transport_observability
  |> E.bind_error (fun error -> E.fail (Error.Http error))
  |> E.bind (fun (response : H.Response.t) ->
         if response.status >= 200 && response.status < 300 then
           E.pure
             {
               inner = A.stream_of_body provider response.body;
               provider_name = provider.A.name;
             }
         else
           read_body response.body
           |> E.bind (fun body ->
                  E.fail
                    (decode_error ~provider:provider.A.name
                       ~status:response.status ~headers:response.headers
                       (Bytes.to_string body))))

let inject_structured_output ~provider structured_output raw =
  match A.Json.parse raw with
  | Stdlib.Error message ->
      Stdlib.Error (Error.Decode { provider; message; raw_body = Some raw })
  | Stdlib.Ok (`Assoc fields) ->
      let format =
        Codec.structured_output_json ~shape:Codec.Chat_response_format
          structured_output
      in
      let fields =
        List.filter (fun (name, _) -> name <> "response_format") fields
        @ [ ("response_format", format) ]
      in
      Stdlib.Ok (A.Json.to_string (`Assoc fields))
  | Stdlib.Ok _ ->
      Stdlib.Error
        (Error.Invalid_request
           {
             provider;
             message =
               "Chat Completions encoder did not return a JSON object";
           })

let chat_completions_request ?structured_output ~provider ~api_key request =
  match provider.A.encode_chat request |> of_neutral_result ~provider:provider.A.name with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw -> (
      match structured_output with
      | None ->
          Stdlib.Ok
            (H.Request.make ~headers:(provider.auth_headers api_key)
               ~body:(H.Request.Fixed [ Bytes.of_string raw ])
               "POST"
               (A.join_url provider.base_url provider.chat_path))
      | Some structured_output -> (
          match
            inject_structured_output ~provider:provider.A.name structured_output
              raw
          with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok raw ->
              Stdlib.Ok
                (H.Request.make ~headers:(provider.auth_headers api_key)
                   ~body:(H.Request.Fixed [ Bytes.of_string raw ])
                   "POST"
                   (A.join_url provider.base_url provider.chat_path))))

let chat_completions ?structured_output ~provider client ~api_key request =
  match chat_completions_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      perform_decoded provider client http_request (fun raw ->
          provider.A.decode_chat raw
          |> of_neutral_result ~provider:provider.A.name)
      |> A.Provider.Telemetry.with_chat_span ~error_view provider request

let stream_chat_completions ?structured_output ~provider client ~api_key request
    =
  let request = { request with A.stream = true } in
  match chat_completions_request ?structured_output ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      perform_stream provider client http_request
      |> A.Provider.Telemetry.with_stream_span ~error_view provider request

let of_stream_ai_error (stream : stream) ai_error =
  let provider =
    if String.equal stream.provider_name "" then default_provider_name
    else stream.provider_name
  in
  Error.of_ai_error ~provider ai_error

let fail_stream_preserving (stream : stream) error =
  E.fail error
  |> E.finally
       (A.close_stream stream.inner |> E.map_error Error.of_ai_error)

let read_stream_event stream =
  A.read_stream_event stream.inner
  |> E.map_error (of_stream_ai_error stream)
  |> E.bind (function
       | Some (A.Stream_error ai_error) ->
           fail_stream_preserving stream (of_stream_ai_error stream ai_error)
       | event -> E.pure event)

let read_stream_events stream =
  let rec loop acc =
    read_stream_event stream
    |> E.bind (function
         | None -> E.pure (List.rev acc)
         | Some event -> loop (event :: acc))
  in
  loop []

let close_stream stream =
  A.close_stream stream.inner
  |> E.map_error (fun ai_error -> of_stream_ai_error stream ai_error)

module Chat = struct
  let encode ~provider request =
    provider.A.encode_chat request
    |> of_neutral_result ~provider:provider.A.name

  let decode ~provider raw =
    provider.A.decode_chat raw |> of_neutral_result ~provider:provider.A.name

  let request ~provider ~api_key chat_request =
    chat_completions_request ~provider ~api_key chat_request

  let run ~provider client ~api_key chat_request =
    chat_completions ~provider client ~api_key chat_request

  let stream ~provider client ~api_key chat_request =
    stream_chat_completions ~provider client ~api_key chat_request

  let chat_completions_request = chat_completions_request
  let chat_completions = chat_completions
  let stream_chat_completions = stream_chat_completions
end

module Embeddings = struct
  let encode ~provider request =
    provider.A.encode_embeddings request
    |> of_neutral_result ~provider:provider.A.name

  let decode ~provider raw =
    provider.A.decode_embeddings raw
    |> of_neutral_result ~provider:provider.A.name

  let request ~provider ~api_key:_ _request =
    unsupported ~provider:provider.A.name "embeddings"

  let run ~provider _client ~api_key:_ _request =
    match unsupported ~provider:provider.A.name "embeddings" with
    | Stdlib.Error error -> E.fail error
    | Stdlib.Ok _ -> assert false
end
