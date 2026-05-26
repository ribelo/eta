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

type headers = Http.Core.Header.t
type api_key = string Redacted.t
let api_key value = Redacted.make ~label:"api_key" value

type model = string
type provider_name = string

type audio_format = Pcm16 | G711_alaw | G711_ulaw | Mp3 | Opus | Wav

type audio_data = Base64 of string | Bytes of bytes

type audio = {
  data : audio_data;
  format : audio_format;
  transcript : string option;
}

type content =
  | Text of string
  | Json of raw_json
  | Audio of audio

let audio_pcm16_base64 ?transcript data = Audio { data = Base64 data; format = Pcm16; transcript }

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

type embedding_request = {
  embedding_model : model;
  encoding_format : string option;
}

type embedding_usage = {
  embedding_input_tokens : int option;
  embedding_raw : (string * string) list;
}

type ai_error =
  | Http_error of Http.Error.t
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
}

type provider = {
  name : provider_name;
  base_url : string;
  chat_path : string;
  auth_headers : api_key -> headers;
  capabilities : capabilities;
  encode_chat : chat_request -> (raw_json, ai_error) result;
  decode_chat : raw_json -> (response, ai_error) result;
  decode_stream_event : sse_event -> (stream_event list, ai_error) result;
  decode_error : status:int -> headers:headers -> raw_json -> ai_error;
}

let join_url base path =
  let base =
    if String.ends_with ~suffix:"/" base then
      String.sub base 0 (String.length base - 1)
    else base
  in
  let path = if String.starts_with ~prefix:"/" path then path else "/" ^ path in
  base ^ path

let provider_request provider api_key raw =
  let headers = provider.auth_headers api_key in
  Http.Request.make ~headers
    ~body:(Http.Request.Fixed [ Bytes.of_string raw ])
    "POST" (join_url provider.base_url provider.chat_path)

let read_response_body body =
  Http.Body.Stream.read_all body
  |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Http_error error))
  |> Eta.Effect.map Bytes.to_string

let result_effect = function
  | Stdlib.Ok value -> Eta.Effect.pure value
  | Stdlib.Error error -> Eta.Effect.fail error

let submit_request client request =
  Http.request client request
  |> Eta.Effect.suppress_observability
  |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Http_error error))

let perform_chat provider client request =
  submit_request client request
  |> Eta.Effect.bind (fun response ->
         if
           response.Http.Response.status >= 200
           && response.status < 300
         then
           read_response_body response.body
           |> Eta.Effect.bind (fun raw ->
                  result_effect (provider.decode_chat raw))
         else
           read_response_body response.body
           |> Eta.Effect.bind (fun raw ->
                  Eta.Effect.fail
                    (provider.decode_error ~status:response.status
                       ~headers:response.headers raw)))

type stream = {
  provider : provider;
  body : Http.Body.Stream.t;
  max_buffer_bytes : int;
  mutable buffer : string;
  mutable pending : stream_event list;
  mutable eof : bool;
  mutable released : bool;
}

let default_max_buffer_bytes = 1024 * 1024

let stream_of_body ?(max_buffer_bytes = default_max_buffer_bytes) provider body
    =
  if max_buffer_bytes <= 0 then invalid_arg "Ai.stream_of_body";
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
           response.Http.Response.status >= 200
           && response.status < 300
         then Eta.Effect.pure (stream_of_body provider response.body)
         else
           read_response_body response.body
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
    Http.Body.Stream.discard stream.body
    |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Http_error error)))

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
      Http.Body.Stream.read stream.body
      |> Eta.Effect.catch (fun error ->
             fail_and_close stream (Http_error error))
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
      if max_events < 0 then invalid_arg "Ai.read_stream_events")
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

let annotate attrs effect =
  List.fold_right
    (fun (key, value) acc -> Eta.Effect.annotate ~key ~value acc)
    attrs effect

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
  match Http.Core.Url.parse provider.base_url with
  | Stdlib.Ok url ->
      [
        ("server.address", Http.Core.Url.host url);
        ("server.port", string_of_int (Http.Core.Url.effective_port url));
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
  | Http_error _ -> "http_error"
  | Provider_error { code = Some code; _ } -> code
  | Provider_error _ -> "provider_error"
  | Decode_error _ -> "decode_error"
  | Invalid_tool _ -> "invalid_tool"
  | Unsupported _ -> "unsupported"

let ai_error_message = function
  | Http_error error -> Http.Error.to_string error
  | Provider_error { message; _ }
  | Decode_error { message; _ }
  | Invalid_tool { message; _ } ->
      message
  | Unsupported { provider; feature } -> provider ^ " unsupported " ^ feature

let with_error_type effect =
  effect
  |> Eta.Effect.catch (fun error ->
         Eta.Effect.fail error
         |> annotate [ ("error.type", ai_error_type error) ])

let with_span ~kind ~name ~attrs effect =
  effect |> with_error_type |> annotate attrs
  |> Eta.Effect.named_kind ~error_renderer:ai_error_message ~kind name

let with_chat_span provider (request : chat_request) effect =
  let effect =
    effect
    |> Eta.Effect.bind (fun response ->
           Eta.Effect.pure response |> annotate (response_attrs response))
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

let with_embeddings_span ?usage provider request effect =
  let attrs =
    common_attrs ~operation:"embeddings" provider
      ~model:request.embedding_model
    @ option_attr "gen_ai.request.encoding_formats" request.encoding_format
    @
    match usage with
    | Some usage -> embedding_usage_attrs usage
    | None -> []
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
