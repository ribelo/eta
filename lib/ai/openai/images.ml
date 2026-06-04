(** OpenAI Images API ([POST /v1/images/generations]). *)

module A = Common.A
module Json = Common.Json

let encode (request : A.Image.request) =
  if A.Json_helpers.is_blank request.prompt then
    Common.unsupported "image prompt must not be empty"
  else
    Stdlib.Ok
      (Common.with_json_fields request.extra
         [
           ("model", Option.map Json.string request.model);
           ("prompt", Some (Json.string request.prompt));
           ("n", Option.map Json.int request.n);
           ("size", Option.map Json.string request.size);
           ("quality", Option.map Json.string request.quality);
           ("response_format", Option.map Json.string request.response_format);
           ("user", Option.map Json.string request.user);
         ]
      |> Json.to_string)

let generated_image json =
  {
    A.Image.url = Json.string_member "url" json;
    base64 = Json.string_member "b64_json" json;
    revised_prompt = Json.string_member "revised_prompt" json;
  }

let decode raw =
  match Common.parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.array_member "data" json with
      | None -> Common.decode_error_result ~raw "image response missing data"
      | Some data ->
          Stdlib.Ok
            {
              A.Image.created = Json.int_member "created" json;
              images = List.map generated_image data;
              usage =
                Option.map Common.Codec.usage (Json.object_member "usage" json);
              raw = Some raw;
            })

let request ?provider:custom_provider ~api_key request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.post_request provider ~path:"/v1/images/generations" ~api_key encode
    request

let run ?provider:custom_provider client ~api_key image_request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.run_raw_decoded provider client
    (request ~provider ~api_key image_request)
    decode
