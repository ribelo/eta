module A = Eta_ai
module E = Eta.Effect
module H = Eta_http
module Json = A.Json
module C = Common

let ( let* ) = Result.bind

type resource = {
  id : string;
  object_ : string option;
  bytes : int64 option;
  created_at : int64 option;
  expires_at : int64 option;
  filename : string option;
  purpose : string option;
  public_url : string option;
  public_url_expires_at : int64 option;
  raw : A.raw_json;
}

type order = Asc | Desc
type sort_by = Created_at | Filename | Size

type list_request = {
  limit : int option;
  order : order option;
  sort_by : sort_by option;
  pagination_token : string option;
  filter : string option;
}

type page = {
  data : resource list;
  continuation : string option;
  raw : A.raw_json;
}

type deleted = {
  id : string;
  object_ : string option;
  deleted : bool;
  raw : A.raw_json;
}

type content_format = Original | Text

type content = {
  content_type : string option;
  bytes : bytes;
}

type public_url = {
  public_url : string;
  expires_at : int64 option;
  raw : A.raw_json;
}

type revocation = {
  id : string option;
  revoked : bool;
  public_url : string option;
  raw : A.raw_json;
}

let endpoint = Option.value ~default:Endpoint.default_inference
let base_url endpoint = Endpoint.inference_base_url endpoint
let content_max_bytes = function
  | Original -> 50 * 1024 * 1024
  | Text -> 256 * 1024 * 1024

let resource_of_json raw json =
  let* id = C.required_string "id" json in
  Ok
    {
      id;
      object_ = Json.string_member "object" json;
      bytes = C.int64_member "bytes" json;
      created_at = C.int64_member "created_at" json;
      expires_at = C.int64_member "expires_at" json;
      filename = Json.string_member "filename" json;
      purpose = Json.string_member "purpose" json;
      public_url = Json.string_member "public_url" json;
      public_url_expires_at = C.int64_member "public_url_expires_at" json;
      raw;
    }

let decode_resource raw =
  let* json = C.parse_json raw in
  resource_of_json raw json

let decode_page raw =
  let* json = C.parse_json raw in
  let* data = C.required_array "data" json in
  let* data =
    C.result_map_all (resource_of_json raw) data
  in
  Ok
    {
      data;
      continuation = Json.string_member "pagination_token" json;
      raw;
    }

let decode_deleted raw =
  let* json = C.parse_json raw in
  let* id = C.required_string "id" json in
  match C.bool_member "deleted" json with
  | Some deleted ->
      Ok
        {
          id;
          object_ = Json.string_member "object" json;
          deleted;
          raw;
        }
  | None -> C.decode_error ~raw_body:raw "deleted is missing or is not boolean"

let decode_public_url raw =
  let* json = C.parse_json raw in
  let* public_url = C.required_string "public_url" json in
  Ok
    {
      public_url;
      expires_at = C.int64_member "expires_at" json;
      raw;
    }

let decode_revocation raw =
  let* json = C.parse_json raw in
  match C.bool_member "revoked" json with
  | Some revoked ->
      Ok
        {
          id = Json.string_member "id" json;
          revoked;
          public_url = Json.string_member "public_url" json;
          raw;
        }
  | None -> C.decode_error ~raw_body:raw "revoked is missing or is not boolean"

let validate_expiry = function
  | None -> Ok ()
  | Some seconds when seconds < 3600 || seconds > 2_592_000 ->
      C.invalid "expires_after must be between 3600 and 2592000 seconds"
  | Some _ -> Ok ()

let upload_request ?endpoint:custom ~api_key ?expires_after_s ?purpose file =
  let* () = validate_expiry expires_after_s in
  let parts =
    (match expires_after_s with
    | None -> []
    | Some seconds ->
        [
          Eta_http.Multipart.Text
            { name = "expires_after"; value = string_of_int seconds };
        ])
    @
    (match purpose with
    | None -> []
    | Some value ->
        [ Eta_http.Multipart.Text { name = "purpose"; value } ])
    @ [
        Eta_http.Multipart.File
          {
            name = "file";
            filename = file.A.filename;
            content_type = file.content_type;
            data = Eta_http.Multipart.Buffered file.data;
          };
      ]
  in
  let* multipart =
    Eta_http.Multipart.make parts
    |> Result.map_error (C.multipart_error ~label:"file upload")
  in
  let base_url = base_url (endpoint custom) in
  let headers =
    C.inference_headers api_key
    |> Eta_http.Core.Header.remove "content-type"
    |> Eta_http.Core.Header.unsafe_add "Content-Type"
         ("multipart/form-data; boundary=" ^ multipart.boundary)
  in
  Ok
    (Eta_http.Request.make ~headers ~body:multipart.body "POST"
       (C.join_url base_url "/v1/files"))

let list_request ?endpoint:custom ~api_key request =
  let* () =
    match request.limit with
    | Some value when value < 1 || value > 100 ->
        C.invalid "file list limit must be between 1 and 100"
    | _ -> Ok ()
  in
  let path =
    C.with_query "/v1/files"
      [
        ("limit", Option.map string_of_int request.limit);
        ( "order",
          Option.map (function Asc -> "asc" | Desc -> "desc") request.order );
        ( "sort_by",
          Option.map
            (function
              | Created_at -> "created_at"
              | Filename -> "filename"
              | Size -> "size")
            request.sort_by );
        ("pagination_token", request.pagination_token);
        ("filter", request.filter);
      ]
  in
  let base_url = base_url (endpoint custom) in
  Ok
    (C.json_request ~headers:(C.inference_headers api_key) ~base_url ~meth:"GET"
       ~path ())

let get_request ?endpoint:custom ~api_key ~file_id () =
  let base_url = base_url (endpoint custom) in
  C.json_request ~headers:(C.inference_headers api_key) ~base_url ~meth:"GET"
    ~path:("/v1/files/" ^ file_id) ()

let delete_request ?endpoint:custom ~api_key ~file_id () =
  let base_url = base_url (endpoint custom) in
  C.json_request ~headers:(C.inference_headers api_key) ~base_url ~meth:"DELETE"
    ~path:("/v1/files/" ^ file_id) ()

let content_request ?endpoint:custom ~api_key ~file_id ~format () =
  let base_url = base_url (endpoint custom) in
  let format = match format with Original -> "original" | Text -> "text" in
  C.json_request ~headers:(C.inference_headers api_key) ~base_url ~meth:"GET"
    ~path:("/v1/files/" ^ file_id ^ "/content?format=" ^ format) ()

let create_public_url_request ?endpoint:custom ~api_key ~file_id
    ?expires_after_s () =
  let* () = validate_expiry expires_after_s in
  let base_url = base_url (endpoint custom) in
  let json =
    Json.object_
      [ ("expires_after", Option.map Json.int expires_after_s) ]
  in
  Ok
    (C.json_request ~headers:(C.inference_headers api_key) ~base_url ~meth:"POST"
       ~path:("/v1/files/" ^ file_id ^ "/public-url") ~json ())

let revoke_public_url_request ?endpoint:custom ~api_key ~file_id () =
  let base_url = base_url (endpoint custom) in
  C.json_request ~headers:(C.inference_headers api_key) ~base_url ~meth:"POST"
    ~path:("/v1/files/" ^ file_id ^ "/public-url/revoke")
    ~json:(Json.object_ []) ()

let run_result ~base_url ~operation client decode request =
  match request with
  | Error error -> E.fail error
  | Ok request -> C.perform_json ~telemetry:`Provider ~base_url ~operation client request decode

let upload ?endpoint:custom client ~api_key ?expires_after_s ?purpose file =
  let endpoint = endpoint custom in
  let base_url = base_url endpoint in
  upload_request ~endpoint ~api_key ?expires_after_s ?purpose file
  |> run_result ~base_url ~operation:"upload_file" client decode_resource

let list ?endpoint:custom client ~api_key request =
  let endpoint = endpoint custom in
  let base_url = base_url endpoint in
  list_request ~endpoint ~api_key request
  |> run_result ~base_url ~operation:"list_files" client decode_page

let get ?endpoint:custom client ~api_key ~file_id =
  let endpoint = endpoint custom in
  let base_url = base_url endpoint in
  C.perform_json ~telemetry:`Provider ~base_url ~operation:"get_file" client
    (get_request ~endpoint ~api_key ~file_id ())
    decode_resource

let delete ?endpoint:custom client ~api_key ~file_id =
  let endpoint = endpoint custom in
  let base_url = base_url endpoint in
  C.perform_json ~telemetry:`Provider ~base_url ~operation:"delete_file" client
    (delete_request ~endpoint ~api_key ~file_id ())
    decode_deleted

let content ?endpoint:custom client ~api_key ~file_id ~format =
  let endpoint = endpoint custom in
  let base_url = base_url endpoint in
  C.perform_response ~telemetry:`Provider ~max_bytes:(content_max_bytes format) ~base_url
    ~operation:"download_file" client
    (content_request ~endpoint ~api_key ~file_id ~format ())
  |> E.map (fun (bytes, headers) ->
         { content_type = C.content_type headers; bytes })

let create_public_url ?endpoint:custom client ~api_key ~file_id
    ?expires_after_s () =
  let endpoint = endpoint custom in
  let base_url = base_url endpoint in
  create_public_url_request ~endpoint ~api_key ~file_id ?expires_after_s ()
  |> run_result ~base_url ~operation:"create_file_public_url" client
       decode_public_url

let revoke_public_url ?endpoint:custom client ~api_key ~file_id =
  let endpoint = endpoint custom in
  let base_url = base_url endpoint in
  C.perform_json ~telemetry:`Provider ~base_url ~operation:"revoke_file_public_url" client
    (revoke_public_url_request ~endpoint ~api_key ~file_id ())
    decode_revocation
