module A = Eta_ai
module E = Eta.Effect
module Json = A.Json
module C = Common

let ( let* ) = Result.bind

type management_key = string Eta_redacted.t
let management_key value = Eta_redacted.make ~label:"xai_management_api_key" value

type field_definition = {
  key : string;
  required : bool option;
  unique : bool option;
  inject_into_chunk : bool option;
  description : string option;
}

type metric_space = Unknown | Cosine | Euclidean | Inner_product

type create_request = {
  collection_name : string;
  team_id : string option;
  collection_description : string option;
  index_configuration : A.Json.t option;
  chunk_configuration : A.Json.t option;
  metric_space : metric_space option;
  field_definitions : field_definition list;
  version : int option;
}

type field_definition_operation = Add | Delete

type field_definition_update = {
  field_definition : field_definition;
  operation : field_definition_operation;
}

type update_request = {
  team_id : string option;
  collection_name : string option;
  collection_description : string option;
  chunk_configuration : A.Json.t option;
  field_definition_updates : field_definition_update list;
}

type resource = {
  collection_id : string;
  collection_name : string option;
  created_at : string option;
  index_configuration : A.Json.t option;
  chunk_configuration : A.Json.t option;
  metric_space : A.Json.t option;
  documents_count : int64 option;
  field_definitions : A.Json.t list;
  raw : A.raw_json;
}

type list_request = {
  limit : int option;
  order : string option;
  sort_by : string option;
  pagination_token : string option;
  filter : string option;
}

type page = {
  collections : resource list;
  continuation : string option;
  raw : A.raw_json;
}

type document = {
  file_metadata : A.Json.t option;
  fields : (string * string) list;
  status : string option;
  error_message : string option;
  last_indexed_at : string option;
  raw : A.Json.t;
}

type document_page = {
  documents : document list;
  continuation : string option;
  raw : A.raw_json;
}

type direct_document = {
  name : string;
  data : bytes;
  content_type : string;
  fields : (string * string) list;
}

let management_endpoint = Option.value ~default:Endpoint.default_management
let management_base_url endpoint = Endpoint.management_base_url endpoint
let inference_endpoint = Option.value ~default:Endpoint.default_inference
let inference_base_url endpoint = Endpoint.inference_base_url endpoint

let field_definition_json field =
  Json.object_
    [
      ("key", Some (Json.string field.key));
      ("required", Option.map Json.bool field.required);
      ("unique", Option.map Json.bool field.unique);
      ("inject_into_chunk", Option.map Json.bool field.inject_into_chunk);
      ("description", Option.map Json.string field.description);
    ]

let fields_json fields =
  Json.object_
    (List.map (fun (key, value) -> (key, Some (Json.string value))) fields)

let create_json (request : create_request) =
  Json.object_
    [
      ("collection_name", Some (Json.string request.collection_name));
      ("team_id", Option.map Json.string request.team_id);
      ( "collection_description",
        Option.map Json.string request.collection_description );
      ("index_configuration", request.index_configuration);
      ("chunk_configuration", request.chunk_configuration);
      ( "metric_space",
        Option.map
          (function
            | Unknown -> Json.string "HNSW_METRIC_UNKNOWN"
            | Cosine -> Json.string "HNSW_METRIC_COSINE"
            | Euclidean -> Json.string "HNSW_METRIC_EUCLIDEAN"
            | Inner_product -> Json.string "HNSW_METRIC_INNER_PRODUCT")
          request.metric_space );
      ( "field_definitions",
        if request.field_definitions = [] then None
        else
          Some
            (Json.array
               (List.map field_definition_json request.field_definitions)) );
      ("version", Option.map Json.int request.version);
    ]

let update_json (request : update_request) =
  let field_definition_update_json update =
    Json.object_
      [
        ("field_definition", Some (field_definition_json update.field_definition));
        ( "operation",
          Some
            (Json.string
               (match update.operation with
               | Add -> "FIELD_DEFINITION_ADD"
               | Delete -> "FIELD_DEFINITION_DELETE")) );
      ]
  in
  Json.object_
    [
      ("team_id", Option.map Json.string request.team_id);
      ("collection_name", Option.map Json.string request.collection_name);
      ( "collection_description",
        Option.map Json.string request.collection_description );
      ("chunk_configuration", request.chunk_configuration);
      ( "field_definition_updates",
        if request.field_definition_updates = [] then None
        else
          Some
            (Json.array
               (List.map field_definition_update_json
                  request.field_definition_updates)) );
    ]

let resource_of_json raw json =
  let* collection_id = C.required_string "collection_id" json in
  Ok
    {
      collection_id;
      collection_name = Json.string_member "collection_name" json;
      created_at = Json.string_member "created_at" json;
      index_configuration = Json.member "index_configuration" json;
      chunk_configuration = Json.member "chunk_configuration" json;
      metric_space = Json.member "metric_space" json;
      documents_count = C.int64_member "documents_count" json;
      field_definitions =
        Json.array_member "field_definitions" json |> Option.value ~default:[];
      raw;
    }

let decode_resource raw =
  let* json = C.parse_json raw in
  resource_of_json raw json

let collection_array json =
  match Json.array_member "collections" json with
  | Some values -> Some values
  | None -> Json.array_member "data" json

let decode_page raw =
  let* json = C.parse_json raw in
  let collections = collection_array json |> Option.value ~default:[] in
  let* collections = C.result_map_all (resource_of_json raw) collections in
  Ok
    {
      collections;
      continuation = Json.string_member "pagination_token" json;
      raw;
    }

let decode_unit raw =
  let* json = C.parse_json raw in
  match json with
  | `Assoc [] -> Ok ()
  | _ -> C.decode_error ~raw_body:raw "expected an empty JSON object"

let string_fields json =
  match C.assoc_member "fields" json with
  | None -> []
  | Some fields ->
      List.filter_map
        (function name, `String value -> Some (name, value) | _ -> None)
        fields

let document_of_json json =
  {
    file_metadata = Json.member "file_metadata" json;
    fields = string_fields json;
    status = Json.string_member "status" json;
    error_message = Json.string_member "error_message" json;
    last_indexed_at = Json.string_member "last_indexed_at" json;
    raw = json;
  }

let decode_document raw =
  let* json = C.parse_json raw in
  Ok (document_of_json json)

let document_array json =
  match Json.array_member "documents" json with
  | Some values -> values
  | None -> Json.array_member "data" json |> Option.value ~default:[]

let decode_document_page raw =
  let* json = C.parse_json raw in
  Ok
    {
      documents = List.map document_of_json (document_array json);
      continuation = Json.string_member "pagination_token" json;
      raw;
    }

let decode_documents raw =
  let* json = C.parse_json raw in
  Ok (List.map document_of_json (document_array json))

let validate_list request =
  match request.limit with
  | Some value when value < 1 || value > 100 ->
      C.invalid "collection list limit must be between 1 and 100"
  | _ -> Ok ()

let list_path prefix request =
  C.with_query prefix
    [
      ("limit", Option.map string_of_int request.limit);
      ("order", request.order);
      ("sort_by", request.sort_by);
      ("pagination_token", request.pagination_token);
      ("filter", request.filter);
    ]

let create_collection_request ?management_endpoint:custom ~management_key
    (request : create_request) =
  if String.trim request.collection_name = "" then
    C.invalid "collection_name must not be empty"
  else
    let management_base_url = management_base_url (management_endpoint custom) in
    Ok
      (C.json_request ~headers:(C.management_headers management_key)
         ~base_url:management_base_url ~meth:"POST" ~path:"/v1/collections"
         ~json:(create_json request) ())

let list_collections_request ?management_endpoint:custom ~management_key request =
  let* () = validate_list request in
  let management_base_url = management_base_url (management_endpoint custom) in
  Ok
    (C.json_request ~headers:(C.management_headers management_key)
       ~base_url:management_base_url ~meth:"GET"
       ~path:(list_path "/v1/collections" request) ())

let get_collection_request ?management_endpoint:custom ~management_key
    ~collection_id () =
  let management_base_url = management_base_url (management_endpoint custom) in
  C.json_request ~headers:(C.management_headers management_key)
    ~base_url:management_base_url ~meth:"GET"
    ~path:("/v1/collections/" ^ collection_id) ()

let update_collection_request ?management_endpoint:custom ~management_key
    ~collection_id request =
  let management_base_url = management_base_url (management_endpoint custom) in
  C.json_request ~headers:(C.management_headers management_key)
    ~base_url:management_base_url ~meth:"PUT"
    ~path:("/v1/collections/" ^ collection_id)
    ~json:(update_json request) ()

let delete_collection_request ?management_endpoint:custom ~management_key
    ~collection_id () =
  let management_base_url = management_base_url (management_endpoint custom) in
  C.json_request ~headers:(C.management_headers management_key)
    ~base_url:management_base_url ~meth:"DELETE"
    ~path:("/v1/collections/" ^ collection_id) ()

let add_file_request ?management_endpoint:custom ~management_key ~collection_id
    ~file_id ?(fields = []) () =
  let management_base_url = management_base_url (management_endpoint custom) in
  C.json_request ~headers:(C.management_headers management_key)
    ~base_url:management_base_url ~meth:"POST"
    ~path:("/v1/collections/" ^ collection_id ^ "/documents/" ^ file_id)
    ~json:(Json.object_ [ ("fields", Some (fields_json fields)) ]) ()

let upload_document_request ?management_endpoint:custom ~management_key
    ~collection_id document =
  let fields = Json.to_string (fields_json document.fields) in
  let parts =
    [
      C.Field ("name", document.name);
      C.File
        {
          name = "data";
          filename = document.name;
          content_type = document.content_type;
          data = document.data;
        };
      C.Field ("content_type", document.content_type);
      C.Field ("fields", fields);
    ]
  in
  let* boundary, body = C.multipart ~label:"collection document" parts in
  let management_base_url = management_base_url (management_endpoint custom) in
  Ok
    (C.multipart_request ~headers:(C.management_headers management_key)
       ~base_url:management_base_url
       ~path:("/v1/collections/" ^ collection_id ^ "/documents")
       boundary body)

let list_documents_request ?management_endpoint:custom ~management_key
    ~collection_id request =
  let* () = validate_list request in
  let management_base_url = management_base_url (management_endpoint custom) in
  Ok
    (C.json_request ~headers:(C.management_headers management_key)
       ~base_url:management_base_url ~meth:"GET"
       ~path:
         (list_path
            ("/v1/collections/" ^ collection_id ^ "/documents")
            request)
       ())

let get_document_request ?management_endpoint:custom ~management_key
    ~collection_id ~file_id () =
  let management_base_url = management_base_url (management_endpoint custom) in
  C.json_request ~headers:(C.management_headers management_key)
    ~base_url:management_base_url ~meth:"GET"
    ~path:
      ("/v1/collections/" ^ collection_id ^ "/documents/" ^ file_id)
    ()

let reindex_document_request ?management_endpoint:custom ~management_key
    ~collection_id ~file_id () =
  let management_base_url = management_base_url (management_endpoint custom) in
  C.json_request ~headers:(C.management_headers management_key)
    ~base_url:management_base_url ~meth:"PATCH"
    ~path:
      ("/v1/collections/" ^ collection_id ^ "/documents/" ^ file_id)
    ~json:(Json.object_ []) ()

let remove_document_request ?management_endpoint:custom ~management_key
    ~collection_id ~file_id () =
  let management_base_url = management_base_url (management_endpoint custom) in
  C.json_request ~headers:(C.management_headers management_key)
    ~base_url:management_base_url ~meth:"DELETE"
    ~path:
      ("/v1/collections/" ^ collection_id ^ "/documents/" ^ file_id)
    ()

let batch_get_documents_request ?management_endpoint:custom ~management_key
    ~collection_id ~file_ids () =
  if file_ids = [] then C.invalid "batchGet requires at least one file_id"
  else
    let management_base_url = management_base_url (management_endpoint custom) in
    let query =
      file_ids |> List.map (fun id -> "file_ids=" ^ id) |> String.concat "&"
    in
    Ok
      (C.json_request ~headers:(C.management_headers management_key)
         ~base_url:management_base_url ~meth:"GET"
         ~path:
           ("/v1/collections/" ^ collection_id
          ^ "/documents:batchGet?" ^ query)
         ())

let run_result ~base_url ~operation client decode request =
  match request with
  | Error error -> E.fail error
  | Ok request -> C.perform_json ~base_url ~operation client request decode

let create_collection ?management_endpoint:custom client ~management_key request =
  let management_endpoint = management_endpoint custom in
  let base_url = management_base_url management_endpoint in
  create_collection_request ~management_endpoint ~management_key request
  |> run_result ~base_url ~operation:"create_collection" client decode_resource

let list_collections ?management_endpoint:custom client ~management_key request =
  let management_endpoint = management_endpoint custom in
  let base_url = management_base_url management_endpoint in
  list_collections_request ~management_endpoint ~management_key request
  |> run_result ~base_url ~operation:"list_collections" client decode_page

let get_collection ?management_endpoint:custom client ~management_key
    ~collection_id =
  let management_endpoint = management_endpoint custom in
  let base_url = management_base_url management_endpoint in
  C.perform_json ~base_url ~operation:"get_collection" client
    (get_collection_request ~management_endpoint ~management_key
       ~collection_id ())
    decode_resource

let update_collection ?management_endpoint:custom client ~management_key
    ~collection_id request =
  let management_endpoint = management_endpoint custom in
  let base_url = management_base_url management_endpoint in
  C.perform_json ~base_url ~operation:"update_collection" client
    (update_collection_request ~management_endpoint ~management_key
       ~collection_id request)
    decode_resource

let delete_collection ?management_endpoint:custom client ~management_key
    ~collection_id =
  let management_endpoint = management_endpoint custom in
  let base_url = management_base_url management_endpoint in
  C.perform_json ~base_url ~operation:"delete_collection" client
    (delete_collection_request ~management_endpoint ~management_key
       ~collection_id ())
    decode_unit

let add_file ?management_endpoint:custom client ~management_key ~collection_id
    ~file_id ?fields () =
  let management_endpoint = management_endpoint custom in
  let base_url = management_base_url management_endpoint in
  C.perform_json ~base_url ~operation:"add_collection_document" client
    (add_file_request ~management_endpoint ~management_key
       ~collection_id ~file_id ?fields ())
    decode_unit

let upload_document ?management_endpoint:custom client ~management_key
    ~collection_id document =
  let management_endpoint = management_endpoint custom in
  let base_url = management_base_url management_endpoint in
  upload_document_request ~management_endpoint ~management_key
    ~collection_id document
  |> run_result ~base_url ~operation:"upload_collection_document" client
       decode_document

let list_documents ?management_endpoint:custom client ~management_key
    ~collection_id request =
  let management_endpoint = management_endpoint custom in
  let base_url = management_base_url management_endpoint in
  list_documents_request ~management_endpoint ~management_key
    ~collection_id request
  |> run_result ~base_url ~operation:"list_collection_documents" client
       decode_document_page

let get_document ?management_endpoint:custom client ~management_key
    ~collection_id ~file_id =
  let management_endpoint = management_endpoint custom in
  let base_url = management_base_url management_endpoint in
  C.perform_json ~base_url ~operation:"get_collection_document" client
    (get_document_request ~management_endpoint ~management_key
       ~collection_id ~file_id ())
    decode_document

let reindex_document ?management_endpoint:custom client ~management_key
    ~collection_id ~file_id =
  let management_endpoint = management_endpoint custom in
  let base_url = management_base_url management_endpoint in
  C.perform_json ~base_url ~operation:"reindex_collection_document" client
    (reindex_document_request ~management_endpoint ~management_key
       ~collection_id ~file_id ())
    decode_unit

let remove_document ?management_endpoint:custom client ~management_key
    ~collection_id ~file_id =
  let management_endpoint = management_endpoint custom in
  let base_url = management_base_url management_endpoint in
  C.perform_json ~base_url ~operation:"remove_collection_document" client
    (remove_document_request ~management_endpoint ~management_key
       ~collection_id ~file_id ())
    decode_unit

let batch_get_documents ?management_endpoint:custom client ~management_key
    ~collection_id ~file_ids =
  let management_endpoint = management_endpoint custom in
  let base_url = management_base_url management_endpoint in
  batch_get_documents_request ~management_endpoint ~management_key
    ~collection_id ~file_ids ()
  |> run_result ~base_url ~operation:"batch_get_collection_documents" client
       decode_documents

type retrieval_mode =
  | Semantic of A.Json.t option
  | Keyword of A.Json.t option
  | Hybrid of A.Json.t option

type search_request = {
  query : string;
  collection_ids : string list;
  rag_pipeline : string option;
  filter : string option;
  limit : int option;
  instructions : string option;
  group_by : A.Json.t option;
  retrieval_mode : retrieval_mode;
}

type match_ = {
  file_id : string option;
  chunk_id : string option;
  chunk_content : string option;
  score : float option;
  collection_ids : string list;
  fields : (string * A.Json.t) list;
  page_number : int option;
  raw : A.Json.t;
}

type search_response = {
  matches : match_ list;
  raw : A.raw_json;
}

let retrieval_mode_json = function
  | Semantic config -> ("semantic", config)
  | Keyword config -> ("keyword", config)
  | Hybrid config -> ("hybrid", config)

let merge_type type_ = function
  | None -> Json.object_ [ ("type", Some (Json.string type_)) ]
  | Some (`Assoc fields) ->
      `Assoc (("type", `String type_) :: List.remove_assoc "type" fields)
  | Some _ -> Json.object_ [ ("type", Some (Json.string type_)) ]

let search_request ?endpoint:custom ~api_key request =
  if String.trim request.query = "" then C.invalid "search query must not be empty"
  else if request.collection_ids = [] then
    C.invalid "document search requires at least one collection_id"
  else
    let* () =
      match request.limit with
      | Some value when value < 1 -> C.invalid "search limit must be positive"
      | _ -> Ok ()
    in
    let type_, config = retrieval_mode_json request.retrieval_mode in
    let source =
      Json.object_
        [
          ("collection_ids", Some (C.json_string_list request.collection_ids));
          ("rag_pipeline", Option.map Json.string request.rag_pipeline);
        ]
    in
    let json =
      Json.object_
        [
          ("query", Some (Json.string request.query));
          ("source", Some source);
          ("filter", Option.map Json.string request.filter);
          ("limit", Option.map Json.int request.limit);
          ("instructions", Option.map Json.string request.instructions);
          ("group_by", request.group_by);
          ("retrieval_mode", Some (merge_type type_ config));
        ]
    in
    let base_url = inference_base_url (inference_endpoint custom) in
    Ok
      (C.json_request ~headers:(C.inference_headers api_key) ~base_url
         ~meth:"POST" ~path:"/v1/documents/search" ~json ())

let match_of_json json =
  {
    file_id = Json.string_member "file_id" json;
    chunk_id = Json.string_member "chunk_id" json;
    chunk_content = Json.string_member "chunk_content" json;
    score = C.float_member "score" json;
    collection_ids =
      Json.array_member "collection_ids" json |> Option.value ~default:[]
      |> List.filter_map (function `String value -> Some value | _ -> None);
    fields = Option.value ~default:[] (C.assoc_member "fields" json);
    page_number = Json.int_member "page_number" json;
    raw = json;
  }

let decode_search raw =
  let* json = C.parse_json raw in
  let* matches = C.required_array "matches" json in
  Ok { matches = List.map match_of_json matches; raw }

let search ?endpoint:custom client ~api_key request =
  let endpoint = inference_endpoint custom in
  let base_url = inference_base_url endpoint in
  search_request ~endpoint ~api_key request
  |> run_result ~base_url ~operation:"search_documents" client decode_search
