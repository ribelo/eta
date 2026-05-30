(** OpenRouter Video API ([POST /api/v1/videos], [GET /api/v1/videos/:id],
    [GET /api/v1/videos/:id/content]). *)

module A = Common.A
module E = Common.E
module H = Common.H
module Json = Common.Json

let encode (request : A.Video.request) =
  if String.equal (String.trim request.prompt) "" then
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
  if String.equal (String.trim job_id) "" then
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
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match encode request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok
        (A.provider_post_request provider ~path:"/api/v1/videos" api_key raw)

let run ?provider:custom_provider client ~api_key video_request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match request ~provider ~api_key video_request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_raw provider client http_request
      |> E.bind (fun raw ->
             match decode raw with
             | Stdlib.Ok response -> E.pure response
             | Stdlib.Error error -> E.fail error)

let create ~provider client ~api_key request =
  run ~provider client ~api_key request

let get_request ?provider:custom_provider ~api_key ~job_id () =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match validate_job_id job_id with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok job_id ->
      Stdlib.Ok
        (A.provider_get_request provider
           ~path:("/api/v1/videos/" ^ job_id) api_key)

let get ?provider:custom_provider client ~api_key ~job_id =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match get_request ~provider ~api_key ~job_id () with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_raw provider client http_request
      |> E.bind (fun raw ->
             match decode raw with
             | Stdlib.Ok response -> E.pure response
             | Stdlib.Error error -> E.fail error)

let get_with_provider ~provider client ~api_key ~job_id =
  get ~provider client ~api_key ~job_id

let content_request ?provider:custom_provider ~api_key
    (request : A.Video.content_request) =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match validate_job_id request.job_id with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok job_id ->
      let index = Option.value ~default:0 request.index in
      if index < 0 then
        Common.invalid_routing "video content index must be non-negative"
      else
        Stdlib.Ok
          (A.provider_get_request provider
             ~path:
               ("/api/v1/videos/" ^ job_id ^ "/content?index="
              ^ string_of_int index)
             api_key)

let content ?provider:custom_provider client ~api_key request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match content_request ~provider ~api_key request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_binary ~max_bytes:(256 * 1024 * 1024) provider client
        http_request
      |> E.map decode_content

let content_with_provider ~provider client ~api_key request =
  content ~provider client ~api_key request
