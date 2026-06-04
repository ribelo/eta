(** OpenRouter Video API ([POST /api/v1/videos], [GET /api/v1/videos/:id],
    [GET /api/v1/videos/:id/content]). *)

module A = Common.A
module H = Common.H
module Json = Common.Json

let encode (request : A.Video.request) =
  if A.Json_helpers.is_blank request.prompt then
    Common.invalid_routing "video prompt must not be empty"
  else
    Stdlib.Ok
      (Common.with_json_fields request.extra
         [
           ("model", Some (Json.string request.model));
           ("prompt", Some (Json.string request.prompt));
           ("aspect_ratio", Option.map Json.string request.aspect_ratio);
           ("duration", Option.map Json.int request.duration);
           ("resolution", Option.map Json.string request.resolution);
         ]
      |> Json.to_string)

let usage_of_json json =
  let raw_value name =
    Json.scalar_string_member name json |> Option.value ~default:""
  in
  {
    A.input_tokens = None;
    output_tokens = None;
    total_tokens = None;
    raw = [ ("cost", raw_value "cost"); ("is_byok", raw_value "is_byok") ];
  }

let decode raw =
  match Common.parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.string_member "id" json with
      | None -> Common.decode_error_result ~raw "video response missing id"
      | Some id ->
          Stdlib.Ok
            {
              A.Video.id;
              generation_id = Json.string_member "generation_id" json;
              status = Json.string_member "status" json;
              polling_url = Json.string_member "polling_url" json;
              urls =
                Json.array_member "unsigned_urls" json
                |> Option.value ~default:[]
                |> List.filter_map (function
                     | `String value -> Some value
                     | _ -> None);
              error = Json.string_member "error" json;
              usage = Option.map usage_of_json (Json.object_member "usage" json);
              raw = Some raw;
            })

let validate_job_id job_id =
  if A.Json_helpers.is_blank job_id then
    Common.invalid_routing "video job_id must not be empty"
  else if
    String.contains job_id '/'
    || String.contains job_id '?'
    || String.contains job_id '#'
  then
    Common.invalid_routing "video job_id contains an invalid path character"
  else Stdlib.Ok job_id

let decode_content (body, headers) =
  {
    A.Video.content_type = H.Core.Header.get "content-type" headers;
    bytes = body;
  }

let request ?provider:custom_provider ~api_key request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.post_request provider ~path:"/api/v1/videos" ~api_key encode request

let run ?provider:custom_provider client ~api_key video_request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.run_raw_decoded provider client
    (request ~provider ~api_key video_request)
    decode

let get_request ?provider:custom_provider ~api_key ~job_id () =
  let provider = Common.default_provider Common.provider custom_provider in
  match validate_job_id job_id with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok job_id ->
      Common.get_request provider ~path:("/api/v1/videos/" ^ job_id) ~api_key

let get ?provider:custom_provider client ~api_key ~job_id =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.run_raw_decoded provider client
    (get_request ~provider ~api_key ~job_id ())
    decode

let content_request ?provider:custom_provider ~api_key
    (request : A.Video.content_request) =
  let provider = Common.default_provider Common.provider custom_provider in
  match validate_job_id request.job_id with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok job_id ->
      let index = Option.value ~default:0 request.index in
      if index < 0 then
        Common.invalid_routing "video content index must be non-negative"
      else
        Common.get_request provider
          ~path:
            ("/api/v1/videos/" ^ job_id ^ "/content?index="
           ^ string_of_int index)
          ~api_key

let content ?provider:custom_provider client ~api_key request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.run_binary ~max_bytes:(256 * 1024 * 1024) provider client
    (content_request ~provider ~api_key request)
    decode_content
