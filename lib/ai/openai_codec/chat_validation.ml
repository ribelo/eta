module A = Eta_ai

type failure =
  | Invalid_request of string
  | Unsupported of string

let sextet = function
  | 'A' .. 'Z' as value -> Char.code value - Char.code 'A'
  | 'a' .. 'z' as value -> Char.code value - Char.code 'a' + 26
  | '0' .. '9' as value -> Char.code value - Char.code '0' + 52
  | '+' -> 62
  | '/' -> 63
  | _ -> -1

let canonical_padded_base64 value =
  let length = String.length value in
  if length mod 4 <> 0 then false
  else
    let padding =
      if length = 0 || value.[length - 1] <> '=' then 0
      else if length >= 2 && value.[length - 2] = '=' then 2
      else 1
    in
    let data_length = length - padding in
    let valid = ref true in
    let index = ref 0 in
    while !valid && !index < data_length do
      valid := sextet value.[!index] >= 0;
      incr index
    done;
    while !valid && !index < length do
      valid := value.[!index] = '=';
      incr index
    done;
    !valid
    &&
    match padding with
    | 0 -> true
    | 1 -> data_length >= 1 && sextet value.[data_length - 1] land 0x03 = 0
    | 2 -> data_length >= 1 && sextet value.[data_length - 1] land 0x0f = 0
    | _ -> false

let content_has_audio =
  List.exists (function A.Audio _ -> true | _ -> false)

let validate_audio audio =
  match audio.A.format with
  | A.Mp3 | A.Wav -> (
      match audio.data with
      | A.Bytes _ -> Stdlib.Ok ()
      | A.Base64 value ->
          if canonical_padded_base64 value then Stdlib.Ok ()
          else
            Stdlib.Error
              (Invalid_request
                 "Chat Completions input audio data must be strict standard padded base64"))
  | A.Pcm16 | A.G711_alaw | A.G711_ulaw | A.Opus ->
      Stdlib.Error
        (Unsupported "Chat Completions input audio format must be mp3 or wav")

let validate_contents contents =
  let rec loop = function
    | [] -> Stdlib.Ok ()
    | A.Audio audio :: rest -> (
        match validate_audio audio with
        | Stdlib.Error _ as error -> error
        | Stdlib.Ok () -> loop rest)
    | _ :: rest -> loop rest
  in
  loop contents

let validate_message = function
  | A.User contents -> validate_contents contents
  | A.Assistant { content; _ } | A.Tool { content; _ }
    when content_has_audio content ->
      Stdlib.Error
        (Unsupported
           "Chat Completions audio content is supported only in user messages")
  | A.System _ | A.Assistant _ | A.Tool _ -> Stdlib.Ok ()

let validate_prompt prompt =
  let rec loop = function
    | [] -> Stdlib.Ok ()
    | message :: rest -> (
        match validate_message message with
        | Stdlib.Error _ as error -> error
        | Stdlib.Ok () -> loop rest)
  in
  loop prompt

let validate request =
  if A.Json_helpers.is_blank request.A.model then
    Stdlib.Error (Invalid_request "Chat Completions model must not be empty")
  else validate_prompt request.prompt

let has_audio request =
  List.exists
    (function
      | A.User contents | A.Assistant { content = contents; _ }
      | A.Tool { content = contents; _ } ->
          content_has_audio contents
      | A.System _ -> false)
    request.A.prompt
