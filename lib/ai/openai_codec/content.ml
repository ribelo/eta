module A = Eta_ai
module Json = A.Json

let content_text = function
  | A.Text text -> Some text
  | A.Json raw -> Some raw
  | A.Audio _ | A.Image _ | A.Video _ -> None

let unsupported ~provider feature =
  Stdlib.Error (A.Unsupported { provider; feature })

let contents_text ~provider contents =
  let rec loop acc = function
    | [] -> Stdlib.Ok (String.concat "" (List.rev acc))
    | content :: rest -> (
        match content_text content with
        | Some text -> loop (text :: acc) rest
        | None -> unsupported ~provider "content cannot be encoded as text")
  in
  loop [] contents

let content_is_text = function A.Text _ | A.Json _ -> true | _ -> false
let contents_are_text contents = List.for_all content_is_text contents

let audio_format = function
  | A.Pcm16 -> "pcm16"
  | A.G711_alaw -> "g711_alaw"
  | A.G711_ulaw -> "g711_ulaw"
  | A.Mp3 -> "mp3"
  | A.Opus -> "opus"
  | A.Wav -> "wav"

let audio_data_base64 = function
  | A.Base64 value -> value
  | A.Bytes bytes -> Base64.encode_string (Bytes.to_string bytes)

let media_object media =
  Json.object_
    [
      ("url", Some (Json.string media.A.url));
      ("detail", Option.map Json.string media.detail);
    ]

let audio_content_part (audio : A.audio) =
  Json.object_
    [
      ("type", Some (Json.string "input_audio"));
      (
        "input_audio",
        Some
          (Json.object_
             [
               ("data", Some (Json.string (audio_data_base64 audio.data)));
               ("format", Some (Json.string (audio_format audio.format)));
             ]) );
    ]

let chat_content_part = function
  | A.Text text -> Json.object_ [ ("type", Some (Json.string "text")); ("text", Some (Json.string text)) ]
  | A.Json raw -> Json.object_ [ ("type", Some (Json.string "text")); ("text", Some (Json.string raw)) ]
  | A.Image media ->
      Json.object_
        [
          ("type", Some (Json.string "image_url"));
          ("image_url", Some (media_object media));
        ]
  | A.Audio audio -> audio_content_part audio
  | A.Video media ->
      Json.object_
        [
          ("type", Some (Json.string "video_url"));
          ("video_url", Some (media_object media));
        ]

let chat_content_json ~provider contents =
  if contents_are_text contents then
    contents_text ~provider contents |> Result.map Json.string
  else Stdlib.Ok (Json.array (List.map chat_content_part contents))

let responses_content_part ~provider = function
  | A.Text text ->
      Stdlib.Ok
        (Json.object_
           [
             ("type", Some (Json.string "input_text"));
             ("text", Some (Json.string text));
           ])
  | A.Json raw ->
      Stdlib.Ok
        (Json.object_
           [
             ("type", Some (Json.string "input_text"));
             ("text", Some (Json.string raw));
           ])
  | A.Image media ->
      Stdlib.Ok
        (Json.object_
           [
             ("type", Some (Json.string "input_image"));
             ("image_url", Some (Json.string media.A.url));
             ("detail", Option.map Json.string media.detail);
           ])
  | A.Audio _ -> unsupported ~provider "audio content in Responses"
  | A.Video media ->
      Stdlib.Ok
        (Json.object_
           [
             ("type", Some (Json.string "input_video"));
             ("video_url", Some (Json.string media.A.url));
           ])

let openrouter_responses_content_part ~provider = function
  | A.Audio audio -> Stdlib.Ok (audio_content_part audio)
  | content -> responses_content_part ~provider content

let responses_content_json_with encode_part ~provider contents =
  if contents_are_text contents then
    contents_text ~provider contents |> Result.map Json.string
  else
    let rec loop acc = function
      | [] -> Stdlib.Ok (Json.array (List.rev acc))
      | content :: rest -> (
          match encode_part ~provider content with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok part -> loop (part :: acc) rest)
    in
    loop [] contents

let responses_tool_content_part ~provider = function
  | A.Text text ->
      Stdlib.Ok
        (Json.object_
           [
             ("type", Some (Json.string "input_text"));
             ("text", Some (Json.string text));
           ])
  | A.Json raw ->
      Stdlib.Ok
        (Json.object_
           [
             ("type", Some (Json.string "input_text"));
             ("text", Some (Json.string raw));
           ])
  | A.Image media ->
      Stdlib.Ok
        (Json.object_
           [
             ("type", Some (Json.string "input_image"));
             ("image_url", Some (Json.string media.A.url));
             ("detail", Option.map Json.string media.detail);
           ])
  | A.Audio _ -> unsupported ~provider "tool result audio content"
  | A.Video _ -> unsupported ~provider "tool result video content"

let responses_tool_content_json ~provider contents =
  if contents_are_text contents then
    contents_text ~provider contents |> Result.map Json.string
  else
    let rec loop acc = function
      | [] -> Stdlib.Ok (Json.array (List.rev acc))
      | content :: rest -> (
          match responses_tool_content_part ~provider content with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok part -> loop (part :: acc) rest)
    in
    loop [] contents

let contents_empty contents =
  match contents with
  | [] -> true
  | _ when contents_are_text contents ->
      (match contents_text ~provider:"openai" contents with
      | Stdlib.Ok text -> String.equal text ""
      | Stdlib.Error _ -> false)
  | _ -> false

let responses_content_json =
  responses_content_json_with responses_content_part

let openrouter_responses_content_json =
  responses_content_json_with openrouter_responses_content_part

let message_item_with encode_content ~provider role contents =
  encode_content ~provider contents
  |> Result.map (fun content ->
         Json.object_
           [
             ("role", Some (Json.string role));
             ("content", Some content);
           ])

let function_call_item (call : A.tool_call) =
  Json.object_
    [
      ("type", Some (Json.string "function_call"));
      ("call_id", Some (Json.string call.id));
      ("name", Some (Json.string call.name));
      ("arguments", Some (Json.string call.arguments_json));
    ]

let message_item = message_item_with responses_content_json
let openrouter_message_item = message_item_with openrouter_responses_content_json

let input_items_with message_item ~provider = function
  | A.System text -> message_item ~provider "system" [ A.Text text ] |> Result.map (fun item -> [ item ])
  | A.User contents -> message_item ~provider "user" contents |> Result.map (fun item -> [ item ])
  | A.Assistant { content; tool_calls } ->
      let content_item =
        if contents_empty content then Stdlib.Ok []
        else message_item ~provider "assistant" content |> Result.map (fun item -> [ item ])
      in
      Result.map
        (fun content_item -> content_item @ List.map function_call_item tool_calls)
        content_item
  | A.Tool { tool_call_id; content } ->
      responses_tool_content_json ~provider content
      |> Result.map (fun output ->
             [
               Json.object_
                 [
                   ("type", Some (Json.string "function_call_output"));
                   ("call_id", Some (Json.string tool_call_id));
                   ("output", Some output);
                 ];
             ])

let input_items = input_items_with message_item
let openrouter_input_items = input_items_with openrouter_message_item

let chat_tool_content_json ~provider contents =
  if contents_are_text contents then
    contents_text ~provider contents |> Result.map Json.string
  else unsupported ~provider "tool result media content"

let chat_validation_error ~provider = function
  | Chat_validation.Invalid_request message ->
      Stdlib.Error (A.Invalid_request { provider; message })
  | Chat_validation.Unsupported feature -> unsupported ~provider feature

let chat_message_json ~provider message =
  match Chat_validation.validate_message message with
  | Stdlib.Error failure -> chat_validation_error ~provider failure
  | Stdlib.Ok () -> (
      match message with
  | A.System content ->
      Stdlib.Ok
        (Json.object_
           [
             ("role", Some (Json.string "system"));
             ("content", Some (Json.string content));
           ])
  | A.User contents ->
      chat_content_json ~provider contents
      |> Result.map (fun content ->
             Json.object_
               [
                 ("role", Some (Json.string "user"));
                 ("content", Some content);
               ])
  | A.Assistant { content; tool_calls } -> (
      let tool_calls =
        match tool_calls with
        | [] -> None
        | calls ->
            calls
            |> List.map (fun (call : A.tool_call) ->
                   Json.object_
                     [
                       ("id", Some (Json.string call.id));
                       ("type", Some (Json.string "function"));
                       ( "function",
                         Some
                           (Json.object_
                              [
                                ("name", Some (Json.string call.name));
                                ("arguments", Some (Json.string call.arguments_json));
                              ]) );
                     ])
            |> Json.array |> Option.some
      in
      match chat_content_json ~provider content with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok content ->
          Stdlib.Ok
            (Json.object_
               [
                 ("role", Some (Json.string "assistant"));
                 ("content", Some content);
                 ("tool_calls", tool_calls);
               ]))
  | A.Tool { tool_call_id; content } ->
      chat_tool_content_json ~provider content
      |> Result.map (fun content ->
             Json.object_
               [
                 ("role", Some (Json.string "tool"));
                 ("tool_call_id", Some (Json.string tool_call_id));
                 ("content", Some content);
               ]))
