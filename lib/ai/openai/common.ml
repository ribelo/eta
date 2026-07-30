(** Shared OpenAI provider plumbing: types, JSON helpers, codec wrappers, and
    provider builders. Endpoint modules ([Chat], [Embeddings], etc.) layer
    request builders and runners on top of this. *)

module A = Eta_ai
module Codec = Eta_ai_openai_codec
module E = Eta.Effect
module Error = Openai_error
module H = Eta_http
module Json = A.Json

let ( let* ) = Result.bind
let provider_name = "openai"

type structured_output = Codec.structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let map_result = function
  | Stdlib.Ok _ as ok -> ok
  | Stdlib.Error error -> Stdlib.Error (Error.of_ai_error error)

let schema_value label raw =
  Codec.schema_value ~provider:provider_name label raw |> map_result

let schema_value_lossless label raw =
  match Json.parse raw with
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
  | Stdlib.Error failure -> Stdlib.Error (Error.of_codec_failure failure)

let encode_chat ?structured_output request =
  match
    Codec.encode_chat_lossless
      ~schema_value:(fun label raw ->
        match schema_value_lossless label raw with
        | Stdlib.Ok json -> Stdlib.Ok json
        | Stdlib.Error failure -> Stdlib.Error failure)
      ?structured_output request
  with
  | Stdlib.Ok raw -> Stdlib.Ok raw
  | Stdlib.Error failure -> Stdlib.Error (Error.of_codec_failure failure)

let reject_responses_field field = function
  | None -> Stdlib.Ok ()
  | Some _ -> Stdlib.Error (Error.Unsupported field)

let normalize_responses_reasoning request =
  match request.A.Responses.reasoning with
  | None -> Stdlib.Ok request
  | Some reasoning -> (
      match reasoning.effort with
      | None -> Stdlib.Ok request
      | Some effort -> (
          match Codec.reasoning_level_of_string_lossless effort with
          | Stdlib.Error failure ->
              Stdlib.Error (Error.of_codec_failure failure)
          | Stdlib.Ok level ->
              let effort =
                match level with
                | Codec.Off -> "none"
                | _ -> Codec.reasoning_level_to_string level
              in
              Stdlib.Ok
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
  match
    Codec.encode_responses_lossless ~provider:provider_name
      ~map_codec_failure:Error.of_codec_failure
      ~encode_tool:(fun tool ->
        Codec.tool_json
          ~schema_value:(Codec.schema_value ~provider:provider_name)
          ~shape:Codec.Responses_tool tool
        |> Result.map_error Error.of_ai_error)
      request
  with
  | Stdlib.Ok raw -> Stdlib.Ok raw
  | Stdlib.Error error -> Stdlib.Error error

let decode_chat raw =
  Codec.decode_chat ~usage_raw_prompt_names:true ~provider:provider_name raw
  |> map_result

let decode_responses raw =
  match Codec.decode_responses ~provider:provider_name raw with
  | Stdlib.Ok _ as ok -> ok
  | Stdlib.Error (A.Provider_error _ as error) ->
      (* 2xx body with status=failed is a structured non-HTTP provider fact. *)
      Stdlib.Error (Error.of_ai_error error)
  | Stdlib.Error error -> Stdlib.Error (Error.of_ai_error error)

let of_stream_failure = function
  | Codec.Decode { message; raw_body } ->
      Error.Decode { message; raw_body }
  | Codec.Provider { payload; raw_body } ->
      Error.of_wire_payload ~raw_body:raw_body payload

let decode_stream_event event =
  match
    Codec.decode_stream_event_lossless ~provider:provider_name event
  with
  | Stdlib.Ok events -> Stdlib.Ok events
  | Stdlib.Error failure -> Stdlib.Error (of_stream_failure failure)

let decode_error ~status ~headers raw = Error.decode ~status ~headers raw

let decode_error_result ?raw message =
  Stdlib.Error (Error.Decode { message; raw_body = raw })

let parse_json raw =
  match Json.parse raw with
  | Stdlib.Ok json -> Stdlib.Ok json
  | Stdlib.Error message -> decode_error_result ~raw message

let unsupported feature = Stdlib.Error (Error.Unsupported feature)
let invalid_request message = Stdlib.Error (Error.Invalid_request message)

let encode_embeddings request =
  match Codec.encode_embeddings_lossless request with
  | Stdlib.Ok raw -> Stdlib.Ok raw
  | Stdlib.Error failure -> Stdlib.Error (Error.of_codec_failure failure)

let decode_embeddings raw =
  Codec.decode_embeddings ~provider:provider_name raw |> map_result

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

let of_neutral_result = function
  | Stdlib.Ok _ as ok -> ok
  | Stdlib.Error error -> Stdlib.Error (Error.of_ai_error error)

let to_neutral_result = function
  | Stdlib.Ok _ as ok -> ok
  | Stdlib.Error error -> Stdlib.Error (Error.to_ai_error error)

let neutral_encode_chat ?structured_output request =
  encode_chat ?structured_output request |> to_neutral_result

let neutral_decode_chat raw = decode_chat raw |> to_neutral_result

let neutral_encode_embeddings request =
  encode_embeddings request |> to_neutral_result

let neutral_decode_embeddings raw = decode_embeddings raw |> to_neutral_result

let neutral_decode_stream_event event =
  (* Neutral provider record still embeds Stream_error for unmigrated hosts. *)
  Codec.decode_stream_event ~provider:provider_name event

let neutral_decode_error ~status ~headers raw =
  decode_error ~status ~headers raw |> Error.to_ai_error

let chat_completions_provider ?(base_url = "https://api.openai.com") () =
  {
    A.name = provider_name;
    base_url;
    chat_path = "/v1/chat/completions";
    embeddings_path = Some "/v1/embeddings";
    auth_headers;
    capabilities;
    encode_chat = (fun request -> neutral_encode_chat request);
    decode_chat =
      (fun raw ->
        Codec.decode_chat ~usage_raw_prompt_names:true ~provider:provider_name
          raw);
    encode_embeddings = neutral_encode_embeddings;
    decode_embeddings = neutral_decode_embeddings;
    decode_stream_event = neutral_decode_stream_event;
    decode_error = neutral_decode_error;
  }

let responses_transport_provider ?(base_url = "https://api.openai.com") () =
  {
    A.name = provider_name;
    base_url;
    chat_path = "/v1/responses";
    embeddings_path = Some "/v1/embeddings";
    auth_headers;
    capabilities;
    encode_chat =
      (fun _ ->
        Error.to_ai_error
          (Error.Unsupported
             "Chat Completions request cannot be sent to the Responses endpoint")
        |> Result.error);
    decode_chat = (fun raw -> decode_responses raw |> to_neutral_result);
    encode_embeddings = neutral_encode_embeddings;
    decode_embeddings = neutral_decode_embeddings;
    decode_stream_event = neutral_decode_stream_event;
    decode_error = neutral_decode_error;
  }

let provider ?base_url () = responses_transport_provider ?base_url ()

let responses_provider ?base_url () =
  {
    A.transport = responses_transport_provider ?base_url ();
    encode_responses =
      (fun request -> encode_responses request |> to_neutral_result);
  }

let default_provider default custom_provider =
  match custom_provider with
  | Some provider -> provider
  | None -> default ()

let join_url = A.join_url
let with_json_fields = Codec.with_json_fields

let error_view : _ A.Provider.Telemetry.error_view =
  { error_type = Error.classification; error_pp = Error.pp }

let post_request provider ~path ~api_key encode request =
  match encode request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok
        (H.Request.make ~headers:(provider.A.auth_headers api_key)
           ~body:(H.Request.Fixed [ Bytes.of_string raw ])
           "POST"
           (join_url provider.base_url path))

let chat_request_from_raw provider ~api_key = function
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok
        (H.Request.make ~headers:(provider.A.auth_headers api_key)
           ~body:(H.Request.Fixed [ Bytes.of_string raw ])
           "POST"
           (join_url provider.base_url provider.chat_path))

let raw_chat_request = chat_request_from_raw

let read_body ?max_bytes body =
  H.Body.Stream.read_all ?max_bytes body
  |> E.bind_error (fun error -> E.fail (Error.Http error))

let perform_response ?max_bytes provider client request =
  H.request client request
  |> A.suppress_provider_transport_observability
  |> E.bind_error (fun error -> E.fail (Error.Http error))
  |> E.bind (fun (response : H.Response.t) ->
         read_body ?max_bytes response.body
         |> E.bind (fun body ->
                if response.status >= 200 && response.status < 300 then
                  E.pure (body, response.headers)
                else
                  E.fail
                    (Error.decode ~status:response.status
                       ~headers:response.headers (Bytes.to_string body))))

let run_request request perform =
  match request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request -> perform http_request

let perform_decoded ?max_bytes provider client request decode =
  perform_response ?max_bytes provider client request
  |> E.bind (fun (body, _) ->
         match decode (Bytes.to_string body) with
         | Stdlib.Ok value -> E.pure value
         | Stdlib.Error error -> E.fail error)

let perform_binary ?max_bytes provider client request =
  perform_response ?max_bytes provider client request

(* Use the configured provider decoder unchanged. Outer stream reads promote
   both outer decode errors and successful Stream_error events into nominal
   Error.t. *)
type stream = { inner : A.stream }

let stream_of_body provider body = { inner = A.stream_of_body provider body }

let perform_stream provider client request =
  H.request client request
  |> A.suppress_provider_transport_observability
  |> E.bind_error (fun error -> E.fail (Error.Http error))
  |> E.bind (fun (response : H.Response.t) ->
         if response.status >= 200 && response.status < 300 then
           E.pure { inner = A.stream_of_body provider response.body }
         else
           read_body response.body
           |> E.bind (fun body ->
                  E.fail
                    (Error.decode ~status:response.status
                       ~headers:response.headers (Bytes.to_string body))))

let run_chat provider client (chat_request : A.chat_request) request =
  run_request request (fun http_request ->
      perform_decoded provider client http_request (fun raw ->
          provider.A.decode_chat raw |> of_neutral_result)
      |> A.Provider.Telemetry.with_chat_span ~error_view provider chat_request)

let run_stream provider client (chat_request : A.chat_request) request =
  run_request request (fun http_request ->
      perform_stream provider client http_request
      |> A.Provider.Telemetry.with_stream_span ~error_view provider chat_request)

let run_responses (responses_provider : _ A.responses_provider) client
    (responses_request : _ A.Responses.request) request =
  let provider = responses_provider.A.transport in
  run_request request (fun http_request ->
      perform_decoded provider client http_request (fun raw ->
          (* Prefer the transport decoder configured on the responses provider. *)
          provider.decode_chat raw |> of_neutral_result)
      |> A.Provider.Telemetry.with_responses_span ~error_view provider
           responses_request)

let run_responses_stream (responses_provider : _ A.responses_provider) client
    (responses_request : _ A.Responses.request) request =
  let provider = responses_provider.A.transport in
  run_request request (fun http_request ->
      perform_stream provider client http_request
      |> A.Provider.Telemetry.with_responses_stream_span ~error_view provider
           responses_request)

let run_embeddings provider client (embedding_request : A.Embedding.request)
    request =
  run_request request (fun http_request ->
      perform_decoded provider client http_request (fun raw ->
          provider.A.decode_embeddings raw |> of_neutral_result)
      |> A.Provider.Telemetry.with_embeddings_span ~error_view provider
           embedding_request)

let run_raw_decoded ?max_bytes provider client request decode =
  run_request request (fun http_request ->
      perform_decoded ?max_bytes provider client http_request decode)

let run_binary ?max_bytes provider client request decode =
  run_request request (fun http_request ->
      perform_binary ?max_bytes provider client http_request |> E.map decode)

(* Primary provider failure with protected cleanup finalizer (Sse.fail_and_close). *)
let fail_stream_preserving (stream : stream) error =
  E.fail error
  |> E.finally
       (A.close_stream stream.inner |> E.map_error Error.of_ai_error)

let of_stream_ai_error = function
  | A.Invalid_request { message; _ } -> Error.Invalid_request message
  | error -> Error.of_ai_error error

let read_stream_event stream =
  A.read_stream_event stream.inner
  |> E.map_error of_stream_ai_error
  |> E.bind (function
       | Some (A.Stream_error ai_error) ->
           fail_stream_preserving stream (of_stream_ai_error ai_error)
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
  A.close_stream stream.inner |> E.map_error Error.of_ai_error
