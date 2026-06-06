module Json = Json

include Types

module Json_helpers = struct
  let is_blank = Eta.String_helpers.is_blank
  let trim = Eta.String_helpers.trim
  let trim_equal = Eta.String_helpers.trim_equal

  let decode_error_result ?raw ~provider message =
    Stdlib.Error (Decode_error { provider; message; raw })

  let parse_json ~provider raw =
    match Json.parse raw with
    | Stdlib.Ok json -> Stdlib.Ok json
    | Stdlib.Error message -> decode_error_result ~provider ~raw message

  let schema_value ~provider label raw =
    match Json.parse raw with
    | Stdlib.Ok json -> Stdlib.Ok json
    | Stdlib.Error message ->
        decode_error_result ~provider ~raw
          (Printf.sprintf "%s must be valid JSON: %s" label message)

  let result_all values =
    let rec loop acc = function
      | [] -> Stdlib.Ok (List.rev acc)
      | Stdlib.Ok value :: rest -> loop (value :: acc) rest
      | Stdlib.Error _ as error :: _ -> error
    in
    loop [] values

  let result_map_all (f) values =
    let rec loop acc = function
      | [] -> Stdlib.Ok (List.rev acc)
      | value :: rest -> (
          match f value with
          | Stdlib.Ok mapped -> loop (mapped :: acc) rest
          | Stdlib.Error _ as error -> error)
    in
    loop [] values
end

type toolkit = Toolkit.t

let make_tool = Toolkit.make_tool
let empty_toolkit = Toolkit.empty_toolkit
let make_toolkit = Toolkit.make_toolkit
let add_tool = Toolkit.add_tool
let find_tool = Toolkit.find_tool
let toolkit_tools = Toolkit.toolkit_tools

type stream = Sse.t

let stream_of_body = Sse.stream_of_body
let read_stream_event = Sse.read_stream_event
let read_stream_events = Sse.read_stream_events
let close_stream = Sse.close_stream

include Transport
include Observability

module Provider = struct
  module type Chat = sig
    val encode : provider:provider -> chat_request -> (raw_json, ai_error) result
    val decode : provider:provider -> raw_json -> (response, ai_error) result

    val request :
      provider:provider ->
      api_key:api_key ->
      chat_request ->
      (Eta_http.Request.t, ai_error) result

    val run :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      chat_request ->
      (response, ai_error) Eta.Effect.t

    val stream :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      chat_request ->
      (stream, ai_error) Eta.Effect.t
  end

  module type Embeddings = sig
    val encode :
      provider:provider -> Embedding.request -> (raw_json, ai_error) result
    val decode :
      provider:provider -> raw_json -> (Embedding.response, ai_error) result

    val request :
      provider:provider ->
      api_key:api_key ->
      Embedding.request ->
      (Eta_http.Request.t, ai_error) result

    val run :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Embedding.request ->
      (Embedding.response, ai_error) Eta.Effect.t
  end

  module type Images = sig
    val generate :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Image.request ->
      (Image.response, ai_error) Eta.Effect.t
  end

  module type Speech = sig
    val create :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Speech.request ->
      (Speech.response, ai_error) Eta.Effect.t
  end

  module type Transcriptions = sig
    val create :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Transcription.request ->
      (Transcription.response, ai_error) Eta.Effect.t
  end

  module type Rerank = sig
    val run :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Rerank.request ->
      (Rerank.response, ai_error) Eta.Effect.t
  end

  module type Video = sig
    val create :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Video.request ->
      (Video.response, ai_error) Eta.Effect.t

    val get :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      job_id:string ->
      (Video.response, ai_error) Eta.Effect.t

    val content :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      Video.content_request ->
      (Video.content, ai_error) Eta.Effect.t
  end

  module Chat = struct
    let encode ~provider request = provider.encode_chat request
    let decode ~provider raw = provider.decode_chat raw

    let request ~provider ~api_key chat_request =
      Transport.chat_request provider ~api_key provider.encode_chat chat_request

    let run ~provider client ~api_key chat_request =
      request ~provider ~api_key chat_request
      |> run_chat_request provider client chat_request

    let stream ~provider client ~api_key chat_request =
      let chat_request = { chat_request with stream = true } in
      request ~provider ~api_key chat_request
      |> run_stream_request provider client chat_request
  end

  module Embeddings = struct
    let encode ~provider request = provider.encode_embeddings request
    let decode ~provider raw = provider.decode_embeddings raw

    let request ~provider ~api_key embedding_request =
      embeddings_request provider ~api_key embedding_request

    let run ~provider client ~api_key embedding_request =
      request ~provider ~api_key embedding_request
      |> run_embeddings_request provider client embedding_request
  end
end
