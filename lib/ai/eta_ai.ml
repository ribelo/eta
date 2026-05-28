type raw_json = string

module Json = struct
  type t = Yojson.Safe.t

  let parse raw =
    try Stdlib.Ok (Yojson.Safe.from_string raw) with
    | Yojson.Json_error message -> Stdlib.Error message

  let to_string json = Yojson.Safe.to_string json
  let compact = to_string
  let string value = `String value
  let bool value = `Bool value
  let int value = `Int value

  let float value =
    if classify_float value = FP_nan || classify_float value = FP_infinite
    then None
    else Some (`Float value)

  let array values = `List values

  let object_ fields =
    fields
    |> List.filter_map (fun (name, value) ->
           Option.map (fun value -> (name, value)) value)
    |> fun fields -> `Assoc fields

  let member name = function
    | `Assoc fields -> List.assoc_opt name fields
    | _ -> None

  let string_member name json =
    match member name json with Some (`String value) -> Some value | _ -> None

  let scalar_string_member name json =
    match member name json with
    | Some (`String value) -> Some value
    | Some (`Int value) -> Some (string_of_int value)
    | Some (`Intlit value) -> Some value
    | Some (`Float value) -> Some (Printf.sprintf "%.17g" value)
    | Some (`Bool value) -> Some (string_of_bool value)
    | _ -> None

  let int_member name json =
    match member name json with
    | Some (`Int value) -> Some value
    | Some (`Intlit value) -> int_of_string_opt value
    | Some (`Float value) -> Some (int_of_float value)
    | _ -> None

  let array_member name json =
    match member name json with Some (`List values) -> Some values | _ -> None

  let object_member name json =
    match member name json with Some (`Assoc _ as value) -> Some value | _ -> None
end

type headers = Eta_http.Core.Header.t
type api_key = string Eta_redacted.t
let api_key value = Eta_redacted.make ~label:"api_key" value

type model = string
type provider_name = string

type audio_format = Pcm16 | G711_alaw | G711_ulaw | Mp3 | Opus | Wav

type audio_data = Base64 of string | Bytes of bytes

type audio = {
  data : audio_data;
  format : audio_format;
  transcript : string option;
}

type media = {
  url : string;
  detail : string option;
}

type content =
  | Text of string
  | Json of raw_json
  | Image of media
  | Audio of audio
  | Video of media

let audio_pcm16_base64 ?transcript data = Audio { data = Base64 data; format = Pcm16; transcript }
let image_url ?detail url = Image { url; detail }
let video_url ?detail url = Video { url; detail }

type tool_call = {
  id : string;
  name : string;
  arguments_json : raw_json;
}

type message =
  | System of string
  | User of content list
  | Assistant of {
      content : content list;
      tool_calls : tool_call list;
    }
  | Tool of {
      tool_call_id : string;
      content : content list;
    }

type prompt = message list

type finish_reason =
  | Stop
  | Length
  | Tool_calls
  | Content_filter
  | Error
  | Other of string

type usage = {
  input_tokens : int option;
  output_tokens : int option;
  total_tokens : int option;
  raw : (string * string) list;
}

type response = {
  id : string option;
  model : model option;
  message : message;
  finish_reasons : finish_reason list;
  usage : usage option;
  raw : raw_json option;
}

type tool = {
  name : string;
  description : string option;
  input_schema_json : raw_json;
  strict : bool option;
}

type chat_request = {
  model : model;
  prompt : prompt;
  tools : tool list;
  temperature : float option;
  max_output_tokens : int option;
  stream : bool;
}

type embedding_input =
  | Embedding_text of string
  | Embedding_texts of string list
  | Embedding_tokens of int list
  | Embedding_token_batches of int list list
  | Embedding_raw_json of raw_json

type embedding_request = {
  embedding_model : model;
  embedding_input : embedding_input;
  encoding_format : string option;
  dimensions : int option;
  user : string option;
}

type embedding_vector =
  | Embedding_float of float list
  | Embedding_base64 of string

type embedding = {
  embedding : embedding_vector;
  embedding_index : int option;
}

type embedding_usage = {
  embedding_input_tokens : int option;
  embedding_total_tokens : int option;
  embedding_raw : (string * string) list;
}

type embedding_response = {
  embedding_id : string option;
  embedding_model : model option;
  embeddings : embedding list;
  embedding_usage : embedding_usage option;
  embedding_raw : raw_json option;
}

type generated_image = {
  image_url : string option;
  image_base64 : string option;
  image_revised_prompt : string option;
}

type image_generation_request = {
  image_model : model option;
  image_prompt : string;
  image_n : int option;
  image_size : string option;
  image_quality : string option;
  image_response_format : string option;
  image_user : string option;
  image_extra : (string * Json.t) list;
}

type image_response = {
  image_created : int option;
  images : generated_image list;
  image_usage : usage option;
  image_raw : raw_json option;
}

type binary_file = {
  filename : string;
  content_type : string;
  data : bytes;
}

type speech_request = {
  speech_model : model;
  speech_input : string;
  speech_voice : string;
  speech_response_format : string option;
  speech_speed : float option;
  speech_instructions : string option;
  speech_extra : (string * Json.t) list;
}

type speech_response = {
  speech_content_type : string option;
  speech_audio : bytes;
}

type transcription_request = {
  transcription_model : model;
  transcription_file : binary_file;
  transcription_language : string option;
  transcription_prompt : string option;
  transcription_response_format : string option;
  transcription_temperature : float option;
  transcription_extra_fields : (string * string) list;
}

type transcription_response = {
  transcription_text : string option;
  transcription_usage : usage option;
  transcription_raw : raw_json option;
}

type rerank_request = {
  rerank_model : model;
  rerank_query : string;
  rerank_documents : string list;
  rerank_top_n : int option;
}

type rerank_result = {
  rerank_index : int;
  rerank_score : float option;
  rerank_document : string option;
}

type rerank_response = {
  rerank_id : string option;
  rerank_model : model option;
  rerank_provider : string option;
  rerank_results : rerank_result list;
  rerank_usage : usage option;
  rerank_raw : raw_json option;
}

type video_request = {
  video_model : model;
  video_prompt : string;
  video_aspect_ratio : string option;
  video_duration : int option;
  video_resolution : string option;
  video_extra : (string * Json.t) list;
}

type video_response = {
  video_id : string;
  video_generation_id : string option;
  video_status : string option;
  video_polling_url : string option;
  video_urls : string list;
  video_error : string option;
  video_usage : usage option;
  video_raw : raw_json option;
}

type video_content_request = {
  video_job_id : string;
  video_index : int option;
}

type video_content = {
  video_content_type : string option;
  video_bytes : bytes;
}

type ai_error =
  | Eta_http_error of Eta_http.Error.t
  | Provider_error of {
      provider : provider_name;
      status : int option;
      code : string option;
      message : string;
      raw : raw_json option;
    }
  | Decode_error of {
      provider : provider_name;
      message : string;
      raw : raw_json option;
    }
  | Invalid_tool of {
      name : string;
      message : string;
    }
  | Unsupported of {
      provider : provider_name;
      feature : string;
    }

module Tool_name_set = Set.Make (String)

type toolkit = { rev_tools : tool list; names : Tool_name_set.t }

let invalid_tool name message = Stdlib.Error (Invalid_tool { name; message })
let normalize_tool_name = String.trim

let validate_tool tool =
  let name = normalize_tool_name tool.name in
  if String.equal name "" then invalid_tool tool.name "tool name is required"
  else if String.equal (String.trim tool.input_schema_json) "" then
    invalid_tool tool.name "input_schema_json is required"
  else Stdlib.Ok { tool with name }

let make_tool ?description ?strict ~name ~input_schema_json () =
  validate_tool { name; description; input_schema_json; strict }

let empty_toolkit = { rev_tools = []; names = Tool_name_set.empty }

let toolkit_tools toolkit = List.rev toolkit.rev_tools

let find_tool name toolkit =
  let name = normalize_tool_name name in
  List.find_opt (fun tool -> String.equal tool.name name) toolkit.rev_tools

let add_tool tool toolkit =
  match validate_tool tool with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok tool ->
      if Tool_name_set.mem tool.name toolkit.names then
        invalid_tool tool.name "tool name already registered"
      else
        Stdlib.Ok
          {
            rev_tools = tool :: toolkit.rev_tools;
            names = Tool_name_set.add tool.name toolkit.names;
          }

let make_toolkit tools =
  let rec loop acc = function
    | [] -> Stdlib.Ok acc
    | tool :: rest -> (
        match add_tool tool acc with
        | Stdlib.Ok acc -> loop acc rest
        | Stdlib.Error _ as error -> error)
  in
  loop empty_toolkit tools

type sse_event = {
  event : string option;
  data : raw_json;
}

type tool_call_delta = {
  index : int option;
  id : string option;
  name : string option;
  arguments_json_delta : string;
}

type stream_event =
  | Stream_message_start of {
      id : string option;
      model : model option;
      raw : raw_json option;
    }
  | Stream_content_delta of string
  | Stream_tool_call_delta of tool_call_delta
  | Stream_finish of finish_reason list
  | Stream_error of ai_error
  | Stream_done

type capabilities = {
  streaming : bool;
  tools : bool;
  tool_choice : bool;
  structured_outputs : bool;
  text : bool;
  image_input : bool;
  audio_input : bool;
  video_input : bool;
  embeddings : bool;
  image_generation : bool;
  speech : bool;
  transcription : bool;
  rerank : bool;
  video_generation : bool;
}

type provider = {
  name : provider_name;
  base_url : string;
  chat_path : string;
  embeddings_path : string option;
  auth_headers : api_key -> headers;
  capabilities : capabilities;
  encode_chat : chat_request -> (raw_json, ai_error) result;
  decode_chat : raw_json -> (response, ai_error) result;
  encode_embeddings : embedding_request -> (raw_json, ai_error) result;
  decode_embeddings : raw_json -> (embedding_response, ai_error) result;
  decode_stream_event : sse_event -> (stream_event list, ai_error) result;
  decode_error : status:int -> headers:headers -> raw_json -> ai_error;
}

let unsupported_result provider feature =
  Stdlib.Error (Unsupported { provider; feature })

let unsupported_embeddings provider =
  unsupported_result provider "embeddings"

let join_url base path =
  let base =
    if String.ends_with ~suffix:"/" base then
      String.sub base 0 (String.length base - 1)
    else base
  in
  let path = if String.starts_with ~prefix:"/" path then path else "/" ^ path in
  base ^ path

let provider_post_request provider ~path api_key raw =
  let headers = provider.auth_headers api_key in
  Eta_http.Request.make ~headers
    ~body:(Eta_http.Request.Fixed [ Bytes.of_string raw ])
    "POST" (join_url provider.base_url path)

let provider_get_request provider ~path api_key =
  let headers = provider.auth_headers api_key in
  Eta_http.Request.make ~headers "GET" (join_url provider.base_url path)

let provider_request provider api_key raw =
  provider_post_request provider ~path:provider.chat_path api_key raw

let provider_embeddings_request provider api_key raw =
  match provider.embeddings_path with
  | Some path -> Stdlib.Ok (provider_post_request provider ~path api_key raw)
  | None -> unsupported_embeddings provider.name

let embeddings_request provider ~api_key request =
  match provider.encode_embeddings request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw -> provider_embeddings_request provider api_key raw

let read_response_body ?max_bytes body =
  Eta_http.Body.Stream.read_all ?max_bytes body
  |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Eta_http_error error))

let read_response_text ?max_bytes body =
  read_response_body ?max_bytes body |> Eta.Effect.map Bytes.to_string

let result_effect = function
  | Stdlib.Ok value -> Eta.Effect.pure value
  | Stdlib.Error error -> Eta.Effect.fail error

let submit_request client request =
  Eta_http.request client request
  |> Eta.Effect.suppress_observability
  |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Eta_http_error error))

let perform_raw ?max_bytes provider client request =
  submit_request client request
  |> Eta.Effect.bind (fun response ->
         if
           response.Eta_http.Response.status >= 200
           && response.status < 300
         then read_response_text ?max_bytes response.body
         else
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  Eta.Effect.fail
                    (provider.decode_error ~status:response.status
                       ~headers:response.headers raw)))

let perform_binary ?max_bytes provider client request =
  submit_request client request
  |> Eta.Effect.bind (fun response ->
         if
           response.Eta_http.Response.status >= 200
           && response.status < 300
         then
           read_response_body ?max_bytes response.body
           |> Eta.Effect.map (fun body -> (body, response.headers))
         else
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  Eta.Effect.fail
                    (provider.decode_error ~status:response.status
                       ~headers:response.headers raw)))

let perform_chat provider client request =
  submit_request client request
  |> Eta.Effect.bind (fun response ->
         if
           response.Eta_http.Response.status >= 200
           && response.status < 300
         then
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  result_effect (provider.decode_chat raw))
         else
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  Eta.Effect.fail
                    (provider.decode_error ~status:response.status
                       ~headers:response.headers raw)))

let perform_embeddings provider client request =
  submit_request client request
  |> Eta.Effect.bind (fun response ->
         if
           response.Eta_http.Response.status >= 200
           && response.status < 300
         then
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  result_effect (provider.decode_embeddings raw))
         else
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  Eta.Effect.fail
                    (provider.decode_error ~status:response.status
                       ~headers:response.headers raw)))

type stream = {
  provider : provider;
  body : Eta_http.Body.Stream.t;
  max_buffer_bytes : int;
  mutable buffer : string;
  mutable pending : stream_event list;
  mutable eof : bool;
  mutable released : bool;
}

let default_max_buffer_bytes = 1024 * 1024

let stream_of_body ?(max_buffer_bytes = default_max_buffer_bytes) provider body
    =
  if max_buffer_bytes <= 0 then invalid_arg "Eta_ai.stream_of_body";
  {
    provider;
    body;
    max_buffer_bytes;
    buffer = "";
    pending = [];
    eof = false;
    released = false;
  }

let perform_stream provider client request =
  submit_request client request
  |> Eta.Effect.bind (fun response ->
         if
           response.Eta_http.Response.status >= 200
           && response.status < 300
         then Eta.Effect.pure (stream_of_body provider response.body)
         else
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  Eta.Effect.fail
                    (provider.decode_error ~status:response.status
                       ~headers:response.headers raw)))

let strip_trailing_cr line =
  let len = String.length line in
  if len > 0 && line.[len - 1] = '\r' then String.sub line 0 (len - 1)
  else line

let field_value line colon =
  let value_start = colon + 1 in
  if value_start < String.length line && line.[value_start] = ' ' then
    String.sub line (value_start + 1) (String.length line - value_start - 1)
  else String.sub line value_start (String.length line - value_start)

let parse_sse_record record =
  let event = ref None in
  let data = ref [] in
  record |> String.split_on_char '\n'
  |> List.iter (fun raw_line ->
         let line = strip_trailing_cr raw_line in
         if line <> "" && line.[0] <> ':' then
           match String.index_opt line ':' with
           | None -> ()
           | Some colon ->
               let field = String.sub line 0 colon in
               let value = field_value line colon in
               if String.equal field "event" then event := Some value
               else if String.equal field "data" then data := value :: !data);
  { event = !event; data = String.concat "\n" (List.rev !data) }

let find_sse_separator s =
  let len = String.length s in
  let rec loop index =
    if index >= len then None
    else if index + 1 < len && s.[index] = '\n' && s.[index + 1] = '\n' then
      Some (index, 2)
    else if
      index + 3 < len && s.[index] = '\r' && s.[index + 1] = '\n'
      && s.[index + 2] = '\r' && s.[index + 3] = '\n'
    then Some (index, 4)
    else loop (index + 1)
  in
  loop 0

let release_stream stream =
  if stream.released then Eta.Effect.unit
  else (
    stream.released <- true;
    Eta_http.Body.Stream.discard stream.body
    |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Eta_http_error error)))

let close_stream stream =
  stream.pending <- [];
  stream.buffer <- "";
  stream.eof <- true;
  release_stream stream

let fail_and_close stream error =
  Eta.Effect.scoped
    (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
       ~release:(fun () -> close_stream stream)
    |> Eta.Effect.bind (fun () -> Eta.Effect.fail error))

let buffer_too_large stream =
  Decode_error
    {
      provider = stream.provider.name;
      message =
        Printf.sprintf "SSE buffer exceeded %d bytes"
          stream.max_buffer_bytes;
      raw = None;
    }

let would_exceed_buffer stream chunk =
  String.length stream.buffer + String.length chunk > stream.max_buffer_bytes

let record_too_large stream record =
  String.length record > stream.max_buffer_bytes

let parse_sse_record_capped stream record =
  if record_too_large stream record then Stdlib.Error (buffer_too_large stream)
  else Stdlib.Ok (parse_sse_record record)

let feed_sse stream chunk =
  if would_exceed_buffer stream chunk then Stdlib.Error (buffer_too_large stream)
  else (
    stream.buffer <- stream.buffer ^ chunk;
    let rec drain acc =
      match find_sse_separator stream.buffer with
      | None -> Stdlib.Ok (List.rev acc)
      | Some (index, sep_len) ->
          let record = String.sub stream.buffer 0 index in
          let rest_start = index + sep_len in
          stream.buffer <-
            String.sub stream.buffer rest_start
              (String.length stream.buffer - rest_start);
          if String.trim record = "" then drain acc
          else
            match parse_sse_record_capped stream record with
            | Stdlib.Ok event -> drain (event :: acc)
            | Stdlib.Error _ as error -> error
    in
    drain [])

let flush_sse stream =
  let record = String.trim stream.buffer in
  stream.buffer <- "";
  if record = "" then Stdlib.Ok []
  else Result.map (fun event -> [ event ]) (parse_sse_record_capped stream record)

let decode_sse_records stream records =
  let rec loop acc = function
    | [] -> Eta.Effect.pure (List.rev acc)
    | record :: rest -> (
        match stream.provider.decode_stream_event record with
        | Ok events -> loop (List.rev_append events acc) rest
        | Error error -> fail_and_close stream error)
  in
  loop [] records

let rec read_stream_event stream =
  match stream.pending with
  | event :: rest ->
      stream.pending <- rest;
      Eta.Effect.pure (Some event)
  | [] when stream.eof -> Eta.Effect.pure None
  | [] ->
      Eta_http.Body.Stream.read stream.body
      |> Eta.Effect.catch (fun error ->
             fail_and_close stream (Eta_http_error error))
	      |> Eta.Effect.bind (function
	           | None ->
	               stream.eof <- true;
	               (match flush_sse stream with
	               | Stdlib.Error error -> fail_and_close stream error
	               | Stdlib.Ok records ->
	                   decode_sse_records stream records
	                   |> Eta.Effect.bind (fun events ->
	                          stream.pending <- events;
	                          release_stream stream
	                          |> Eta.Effect.bind (fun () -> read_stream_event stream)))
	           | Some chunk ->
	               (match feed_sse stream (Bytes.to_string chunk) with
	               | Stdlib.Error error -> fail_and_close stream error
	               | Stdlib.Ok records ->
	                   decode_sse_records stream records
	                   |> Eta.Effect.bind (fun events ->
	                          stream.pending <- events;
	                          read_stream_event stream)))

let read_stream_events ?max_events stream =
  Option.iter
    (fun max_events ->
      if max_events < 0 then invalid_arg "Eta_ai.read_stream_events")
    max_events;
  let rec loop remaining acc =
    match remaining with
    | Some 0 ->
        close_stream stream |> Eta.Effect.bind (fun () ->
            Eta.Effect.pure (List.rev acc))
    | _ -> (
        read_stream_event stream |> Eta.Effect.bind (function
          | None -> Eta.Effect.pure (List.rev acc)
          | Some event ->
              let remaining =
                Option.map (fun value -> value - 1) remaining
              in
              loop remaining (event :: acc)))
  in
  loop max_events []

let option_attr key = function
  | Some value -> [ (key, value) ]
  | None -> []

let option_int_attr key = function
  | Some value -> [ (key, string_of_int value) ]
  | None -> []

let option_float_attr key = function
  | Some value -> [ (key, Printf.sprintf "%.3f" value) ]
  | None -> []

let finish_reason_to_string = function
  | Stop -> "stop"
  | Length -> "length"
  | Tool_calls -> "tool_calls"
  | Content_filter -> "content_filter"
  | Error -> "error"
  | Other value -> value

let finish_reasons_to_string reasons =
  reasons |> List.map finish_reason_to_string |> String.concat ","

let usage_attrs (usage : usage) =
  option_int_attr "gen_ai.usage.input_tokens" usage.input_tokens
  @ option_int_attr "gen_ai.usage.output_tokens" usage.output_tokens

let response_attrs (response : response) =
  option_attr "gen_ai.response.id" response.id
  @ option_attr "gen_ai.response.model" response.model
  @ (match response.finish_reasons with
    | [] -> []
    | reasons ->
        [ ("gen_ai.response.finish_reasons", finish_reasons_to_string reasons) ])
  @
  match response.usage with
  | Some usage -> usage_attrs usage
  | None -> []

let provider_server_attrs (provider : provider) =
  match Eta_http.Core.Url.parse provider.base_url with
  | Stdlib.Ok url ->
      [
        ("server.address", Eta_http.Core.Url.host url);
        ("server.port", string_of_int (Eta_http.Core.Url.effective_port url));
      ]
  | Stdlib.Error _ -> []

let common_attrs ~operation (provider : provider) ~model =
  [
    ("gen_ai.operation.name", operation);
    ("gen_ai.provider.name", provider.name);
    ("gen_ai.request.model", model);
  ]
  @ provider_server_attrs provider

let ai_error_type = function
  | Eta_http_error _ -> "http_error"
  | Provider_error { code = Some code; _ } -> code
  | Provider_error _ -> "provider_error"
  | Decode_error _ -> "decode_error"
  | Invalid_tool _ -> "invalid_tool"
  | Unsupported _ -> "unsupported"

let ai_error_message = function
  | Eta_http_error error -> Eta_http.Error.to_string error
  | Provider_error { message; _ }
  | Decode_error { message; _ }
  | Invalid_tool { message; _ } ->
      message
  | Unsupported { provider; feature } -> provider ^ " unsupported " ^ feature

let with_error_type effect =
  effect
  |> Eta.Effect.catch (fun error ->
         Eta.Effect.fail error
         |> Eta.Effect.annotate_all [ ("error.type", ai_error_type error) ])

let with_span ~kind ~name ~attrs effect =
  effect |> with_error_type |> Eta.Effect.annotate_all attrs
  |> Eta.Effect.named_kind ~error_renderer:ai_error_message ~kind name

let with_chat_span provider (request : chat_request) effect =
  let effect =
    effect
    |> Eta.Effect.bind (fun response ->
           Eta.Effect.pure response
           |> Eta.Effect.annotate_all (response_attrs response))
  in
  let attrs =
    common_attrs ~operation:"chat" provider ~model:request.model
    @ if request.stream then [ ("gen_ai.request.stream", "true") ] else []
  in
  with_span ~kind:Eta.Capabilities.Client
    ~name:("chat " ^ request.model)
    ~attrs effect

let with_stream_span ?time_to_first_chunk_s provider (request : chat_request)
    effect =
  let attrs =
    common_attrs ~operation:"chat" provider ~model:request.model
    @ [ ("gen_ai.request.stream", "true") ]
    @ option_float_attr "gen_ai.response.time_to_first_chunk"
        time_to_first_chunk_s
  in
  with_span ~kind:Eta.Capabilities.Client
    ~name:("chat " ^ request.model)
    ~attrs effect

let embedding_usage_attrs (usage : embedding_usage) =
  option_int_attr "gen_ai.usage.input_tokens" usage.embedding_input_tokens
  @ option_int_attr "gen_ai.usage.total_tokens" usage.embedding_total_tokens

let embedding_response_attrs (response : embedding_response) =
  option_attr "gen_ai.response.id" response.embedding_id
  @ option_attr "gen_ai.response.model" response.embedding_model
  @
  match response.embedding_usage with
  | Some usage -> embedding_usage_attrs usage
  | None -> []

let with_embeddings_span provider (request : embedding_request) effect =
  let effect =
    effect
    |> Eta.Effect.bind (fun response ->
           Eta.Effect.pure response
           |> Eta.Effect.annotate_all (embedding_response_attrs response))
  in
  let attrs =
    common_attrs ~operation:"embeddings" provider
      ~model:request.embedding_model
    @ option_attr "gen_ai.request.encoding_formats" request.encoding_format
  in
  with_span ~kind:Eta.Capabilities.Client
    ~name:("embeddings " ^ request.embedding_model)
    ~attrs effect

let with_tool_span ?tool_call_id ?(tool_type = "function") ~tool_name effect =
  let attrs =
    [
      ("gen_ai.operation.name", "execute_tool");
      ("gen_ai.tool.name", tool_name);
      ("gen_ai.tool.type", tool_type);
    ]
    @ option_attr "gen_ai.tool.call.id" tool_call_id
  in
  with_span ~kind:Eta.Capabilities.Internal
    ~name:("execute_tool " ^ tool_name)
    ~attrs effect

let suppress_provider_transport_observability =
  Eta.Effect.suppress_observability

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
      provider:provider -> embedding_request -> (raw_json, ai_error) result
    val decode :
      provider:provider -> raw_json -> (embedding_response, ai_error) result

    val request :
      provider:provider ->
      api_key:api_key ->
      embedding_request ->
      (Eta_http.Request.t, ai_error) result

    val run :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      embedding_request ->
      (embedding_response, ai_error) Eta.Effect.t
  end

  module type Images = sig
    val generate :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      image_generation_request ->
      (image_response, ai_error) Eta.Effect.t
  end

  module type Speech = sig
    val create :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      speech_request ->
      (speech_response, ai_error) Eta.Effect.t
  end

  module type Transcriptions = sig
    val create :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      transcription_request ->
      (transcription_response, ai_error) Eta.Effect.t
  end

  module type Rerank = sig
    val run :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      rerank_request ->
      (rerank_response, ai_error) Eta.Effect.t
  end

  module type Video = sig
    val create :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      video_request ->
      (video_response, ai_error) Eta.Effect.t

    val get :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      job_id:string ->
      (video_response, ai_error) Eta.Effect.t

    val content :
      provider:provider ->
      Eta_http.Client.t ->
      api_key:api_key ->
      video_content_request ->
      (video_content, ai_error) Eta.Effect.t
  end

  module Chat = struct
    let encode ~provider request = provider.encode_chat request
    let decode ~provider raw = provider.decode_chat raw

    let request ~provider ~api_key chat_request =
      match provider.encode_chat chat_request with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok raw -> Stdlib.Ok (provider_request provider api_key raw)

    let run ~provider client ~api_key chat_request =
      match request ~provider ~api_key chat_request with
      | Stdlib.Error error -> Eta.Effect.fail error
      | Stdlib.Ok http_request ->
          with_chat_span provider chat_request
            (perform_chat provider client http_request)

    let stream ~provider client ~api_key chat_request =
      let chat_request = { chat_request with stream = true } in
      match request ~provider ~api_key chat_request with
      | Stdlib.Error error -> Eta.Effect.fail error
      | Stdlib.Ok http_request ->
          with_stream_span provider chat_request
            (perform_stream provider client http_request)
  end

  module Embeddings = struct
    let encode ~provider request = provider.encode_embeddings request
    let decode ~provider raw = provider.decode_embeddings raw

    let request ~provider ~api_key embedding_request =
      embeddings_request provider ~api_key embedding_request

    let run ~provider client ~api_key embedding_request =
      match request ~provider ~api_key embedding_request with
      | Stdlib.Error error -> Eta.Effect.fail error
      | Stdlib.Ok http_request ->
          with_embeddings_span provider embedding_request
            (perform_embeddings provider client http_request)
  end
end
