module A = Eta_ai
module Json = A.Json

let content_text = function
  | A.Text text -> text
  | A.Json raw -> raw
  | A.Audio _ -> invalid_arg "audio content cannot be encoded as text"
  | A.Image _ -> invalid_arg "image content cannot be encoded as text"
  | A.Video _ -> invalid_arg "video content cannot be encoded as text"

let contents_text contents = contents |> List.map content_text |> String.concat ""

let content_has_audio = function
  | A.Audio _ -> true
  | A.Text _ | A.Json _ | A.Image _ | A.Video _ -> false

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

let chat_content_part = function
  | A.Text text -> Json.object_ [ ("type", Some (Json.string "text")); ("text", Some (Json.string text)) ]
  | A.Json raw -> Json.object_ [ ("type", Some (Json.string "text")); ("text", Some (Json.string raw)) ]
  | A.Image media ->
      Json.object_
        [
          ("type", Some (Json.string "url"));
          ("url", Some (media_object media));
        ]
  | A.Audio audio ->
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
  | A.Video media ->
      Json.object_
        [
          ("type", Some (Json.string "video_url"));
          ("video_url", Some (media_object media));
        ]

let chat_content_json contents =
  if contents_are_text contents then Json.string (contents_text contents)
  else Json.array (List.map chat_content_part contents)

let responses_content_part = function
  | A.Text text -> Json.object_ [ ("type", Some (Json.string "input_text")); ("text", Some (Json.string text)) ]
  | A.Json raw -> Json.object_ [ ("type", Some (Json.string "input_text")); ("text", Some (Json.string raw)) ]
  | A.Image media ->
      Json.object_
        [
          ("type", Some (Json.string "input_image"));
          ("url", Some (Json.string media.A.url));
          ("detail", Option.map Json.string media.detail);
        ]
  | A.Audio audio ->
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
  | A.Video media ->
      Json.object_
        [
          ("type", Some (Json.string "input_video"));
          ("video_url", Some (Json.string media.A.url));
        ]

let responses_content_json contents =
  if contents_are_text contents then Json.string (contents_text contents)
  else Json.array (List.map responses_content_part contents)

let contents_empty contents =
  match contents with
  | [] -> true
  | _ when contents_are_text contents -> String.equal (contents_text contents) ""
  | _ -> false

let message_has_audio = function
  | A.System _ -> false
  | A.User contents | A.Assistant { content = contents; _ }
  | A.Tool { content = contents; _ } ->
      List.exists content_has_audio contents

let reject_audio_prompt ~provider prompt =
  if List.exists message_has_audio prompt then
    Stdlib.Error
      (A.Unsupported
         { provider; feature = "audio content requires OpenAI Realtime" })
  else Stdlib.Ok ()

let message_item role contents =
  Json.object_
    [
      ("role", Some (Json.string role));
      ("content", Some (responses_content_json contents));
    ]

let function_call_item (call : A.tool_call) =
  Json.object_
    [
      ("type", Some (Json.string "function_call"));
      ("call_id", Some (Json.string call.id));
      ("name", Some (Json.string call.name));
      ("arguments", Some (Json.string call.arguments_json));
    ]

let input_items = function
  | A.System text -> [ message_item "system" [ A.Text text ] ]
  | A.User contents -> [ message_item "user" contents ]
  | A.Assistant { content; tool_calls } ->
      let content_item =
        if contents_empty content then []
        else [ message_item "assistant" content ]
      in
      content_item @ List.map function_call_item tool_calls
  | A.Tool { tool_call_id; content } ->
      [
        Json.object_
          [
            ("type", Some (Json.string "function_call_output"));
            ("call_id", Some (Json.string tool_call_id));
            ("output", Some (Json.string (contents_text content)));
          ];
      ]

let chat_message_json = function
  | A.System content ->
      Json.object_
        [
          ("role", Some (Json.string "system"));
          ("content", Some (Json.string content));
        ]
  | A.User contents ->
      Json.object_
        [
          ("role", Some (Json.string "user"));
          ("content", Some (chat_content_json contents));
        ]
  | A.Assistant { content; tool_calls } ->
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
      Json.object_
        [
          ("role", Some (Json.string "assistant"));
          ("content", Some (chat_content_json content));
          ("tool_calls", tool_calls);
        ]
  | A.Tool { tool_call_id; content } ->
      Json.object_
        [
          ("role", Some (Json.string "tool"));
          ("tool_call_id", Some (Json.string tool_call_id));
          ("content", Some (chat_content_json content));
        ]


