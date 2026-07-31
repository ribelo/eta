(** OpenAI legacy Chat Completions API ([POST /v1/chat/completions]). Kept for
    callers using the older OpenAI envelope; new code should prefer
    [Responses]. JSON encoding/decoding is delegated to
    [Eta_ai_openai_codec] via [Common]. *)

module A = Common.A
module Codec = Common.Codec
module Json = Common.Json

let inject_structured_output structured_output raw =
  match Json.parse raw with
  | Stdlib.Error message ->
      Stdlib.Error
        (Common.Error.Decode { message; raw_body = Some raw })
  | Stdlib.Ok (`Assoc fields) ->
      let format =
        Codec.structured_output_json ~shape:Codec.Chat_response_format
          structured_output
      in
      let fields =
        List.filter (fun (name, _) -> name <> "response_format") fields
        @ [ ("response_format", format) ]
      in
      Stdlib.Ok (Json.to_string (`Assoc fields))
  | Stdlib.Ok _ ->
      Stdlib.Error
        (Common.Error.Invalid_request
           "Chat Completions encoder did not return a JSON object")
