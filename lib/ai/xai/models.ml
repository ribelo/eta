module A = Eta_ai
module Json = A.Json
module C = Common

let ( let* ) = Result.bind

type model = {
  id : string;
  aliases : string list;
  created : int64 option;
  object_ : string option;
  owned_by : string option;
  context_length : int64 option;
  prompt_text_token_price : int64 option;
  cached_prompt_text_token_price : int64 option;
  prompt_image_token_price : int64 option;
  completion_text_token_price : int64 option;
  long_context_threshold : int64 option;
  image_price : int64 option;
  raw : A.Json.t;
}

type language_model = {
  id : string;
  fingerprint : string option;
  version : string option;
  input_modalities : string list;
  output_modalities : string list;
  search_price : int64 option;
  aliases : string list;
  raw : A.Json.t;
}

type catalog_model = {
  id : string;
  aliases : string list;
  raw : A.Json.t;
}

let strings name json =
  Json.array_member name json |> Option.value ~default:[]
  |> List.filter_map (function `String value -> Some value | _ -> None)

let model_of_json json =
  let* id = C.required_string "id" json in
  Ok
    {
      id;
      aliases = strings "aliases" json;
      created = C.int64_member "created" json;
      object_ = Json.string_member "object" json;
      owned_by = Json.string_member "owned_by" json;
      context_length = C.int64_member "context_length" json;
      prompt_text_token_price = C.int64_member "prompt_text_token_price" json;
      cached_prompt_text_token_price =
        C.int64_member "cached_prompt_text_token_price" json;
      prompt_image_token_price = C.int64_member "prompt_image_token_price" json;
      completion_text_token_price =
        C.int64_member "completion_text_token_price" json;
      long_context_threshold = C.int64_member "long_context_threshold" json;
      image_price = C.int64_member "image_price" json;
      raw = json;
    }

let language_model_of_json json =
  let* id = C.required_string "id" json in
  Ok
    {
      id;
      fingerprint = Json.string_member "fingerprint" json;
      version = Json.string_member "version" json;
      input_modalities = strings "input_modalities" json;
      output_modalities = strings "output_modalities" json;
      search_price = C.int64_member "search_price" json;
      aliases = strings "aliases" json;
      raw = json;
    }

let catalog_model_of_json json =
  let* id = C.required_string "id" json in
  Ok { id; aliases = strings "aliases" json; raw = json }

let endpoint = Option.value ~default:Endpoint.default_inference
let base_url endpoint = Endpoint.inference_base_url endpoint

let get_request ?endpoint:custom ~api_key path =
  let base_url = base_url (endpoint custom) in
  C.json_request ~headers:(C.inference_headers api_key) ~base_url ~meth:"GET"
    ~path ()

let models_request ?endpoint ~api_key () =
  get_request ?endpoint ~api_key "/v1/models"
let model_request ?endpoint ~api_key ~model_id () =
  get_request ?endpoint ~api_key ("/v1/models/" ^ model_id)
let language_models_request ?endpoint ~api_key () =
  get_request ?endpoint ~api_key "/v1/language-models"
let language_model_request ?endpoint ~api_key ~model_id () =
  get_request ?endpoint ~api_key ("/v1/language-models/" ^ model_id)
let embedding_models_request ?endpoint ~api_key () =
  get_request ?endpoint ~api_key "/v1/embedding-models"
let embedding_model_request ?endpoint ~api_key ~model_id () =
  get_request ?endpoint ~api_key ("/v1/embedding-models/" ^ model_id)
let image_generation_models_request ?endpoint ~api_key () =
  get_request ?endpoint ~api_key "/v1/image-generation-models"
let image_generation_model_request ?endpoint ~api_key ~model_id () =
  get_request ?endpoint ~api_key ("/v1/image-generation-models/" ^ model_id)
let video_generation_models_request ?endpoint ~api_key () =
  get_request ?endpoint ~api_key "/v1/video-generation-models"
let video_generation_model_request ?endpoint ~api_key ~model_id () =
  get_request ?endpoint ~api_key ("/v1/video-generation-models/" ^ model_id)

let decode_one decoder raw =
  let* json = C.parse_json raw in
  decoder json

let decode_list decoder raw =
  let* json = C.parse_json raw in
  let values =
    match Json.array_member "data" json with
    | Some values -> values
    | None -> Json.array_member "models" json |> Option.value ~default:[]
  in
  C.result_map_all decoder values

let run ?endpoint:custom ~operation client request decode =
  let base_url = base_url (endpoint custom) in
  C.perform_json ~base_url ~operation client request decode

let list_models ?endpoint client ~api_key =
  run ?endpoint ~operation:"list_models" client
    (models_request ?endpoint ~api_key ())
    (decode_list model_of_json)
let get_model ?endpoint client ~api_key ~model_id =
  run ?endpoint ~operation:"get_model" client
    (model_request ?endpoint ~api_key ~model_id ())
    (decode_one model_of_json)
let list_language_models ?endpoint client ~api_key =
  run ?endpoint ~operation:"list_language_models" client
    (language_models_request ?endpoint ~api_key ())
    (decode_list language_model_of_json)
let get_language_model ?endpoint client ~api_key ~model_id =
  run ?endpoint ~operation:"get_language_model" client
    (language_model_request ?endpoint ~api_key ~model_id ())
    (decode_one language_model_of_json)
let list_embedding_models ?endpoint client ~api_key =
  run ?endpoint ~operation:"list_embedding_models" client
    (embedding_models_request ?endpoint ~api_key ())
    (decode_list catalog_model_of_json)
let get_embedding_model ?endpoint client ~api_key ~model_id =
  run ?endpoint ~operation:"get_embedding_model" client
    (embedding_model_request ?endpoint ~api_key ~model_id ())
    (decode_one catalog_model_of_json)
let list_image_generation_models ?endpoint client ~api_key =
  run ?endpoint ~operation:"list_image_generation_models" client
    (image_generation_models_request ?endpoint ~api_key ())
    (decode_list catalog_model_of_json)
let get_image_generation_model ?endpoint client ~api_key ~model_id =
  run ?endpoint ~operation:"get_image_generation_model" client
    (image_generation_model_request ?endpoint ~api_key ~model_id ())
    (decode_one catalog_model_of_json)
let list_video_generation_models ?endpoint client ~api_key =
  run ?endpoint ~operation:"list_video_generation_models" client
    (video_generation_models_request ?endpoint ~api_key ())
    (decode_list catalog_model_of_json)
let get_video_generation_model ?endpoint client ~api_key ~model_id =
  run ?endpoint ~operation:"get_video_generation_model" client
    (video_generation_model_request ?endpoint ~api_key ~model_id ())
    (decode_one catalog_model_of_json)
