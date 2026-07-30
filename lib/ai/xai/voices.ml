module A = Eta_ai
module E = Eta.Effect
module Json = A.Json
module C = Common

let ( let* ) = Result.bind

type built_in = {
  voice_id : string;
  name : string option;
  language : string option;
  raw : A.Json.t;
}

type custom = {
  voice_id : string;
  name : string option;
  description : string option;
  language : string option;
  created_at : string option;
  raw : A.Json.t;
}

type custom_page = {
  voices : custom list;
  continuation : string option;
  raw : A.raw_json;
}

type audio = {
  content_type : string option;
  bytes : bytes;
}

let endpoint = Option.value ~default:Endpoint.default_inference
let base_url endpoint = Endpoint.inference_base_url endpoint
let reference_audio_max_bytes = 128 * 1024 * 1024

let get_request ?endpoint:custom ~api_key path =
  let base_url = base_url (endpoint custom) in
  C.json_request ~headers:(C.inference_headers api_key) ~base_url ~meth:"GET"
    ~path ()

let built_in_list_request ?endpoint ~api_key () =
  get_request ?endpoint ~api_key "/v1/tts/voices"

let built_in_get_request ?endpoint ~api_key ~voice_id () =
  get_request ?endpoint ~api_key ("/v1/tts/voices/" ^ voice_id)

let custom_list_request ?endpoint:custom ~api_key ?limit ?pagination_token () =
  let* () =
    match limit with
    | Some value when value < 1 || value > 1000 ->
        C.invalid "custom voice list limit must be between 1 and 1000"
    | _ -> Ok ()
  in
  let path =
    C.with_query "/v1/custom-voices"
      [
        ("limit", Option.map string_of_int limit);
        ("pagination_token", pagination_token);
      ]
  in
  Ok (get_request ?endpoint:custom ~api_key path)

let custom_get_request ?endpoint ~api_key ~voice_id () =
  get_request ?endpoint ~api_key ("/v1/custom-voices/" ^ voice_id)

let custom_audio_request ?endpoint ~api_key ~voice_id () =
  get_request ?endpoint ~api_key ("/v1/custom-voices/" ^ voice_id ^ "/audio")

let built_in json =
  let* voice_id = C.required_string "voice_id" json in
  Ok
    {
      voice_id;
      name = Json.string_member "name" json;
      language = Json.string_member "language" json;
      raw = json;
    }

let custom json =
  let* voice_id = C.required_string "voice_id" json in
  Ok
    {
      voice_id;
      name = Json.string_member "name" json;
      description = Json.string_member "description" json;
      language = Json.string_member "language" json;
      created_at = Json.string_member "created_at" json;
      raw = json;
    }

let decode_one decoder raw =
  let* json = C.parse_json raw in
  decoder json

let decode_built_ins raw =
  let* json = C.parse_json raw in
  let values = Json.array_member "voices" json |> Option.value ~default:[] in
  C.result_map_all built_in values

let decode_custom_page raw =
  let* json = C.parse_json raw in
  let values =
    match Json.array_member "voices" json with
    | Some values -> values
    | None -> Json.array_member "data" json |> Option.value ~default:[]
  in
  let* voices = C.result_map_all custom values in
  Ok
    {
      voices;
      continuation = Json.string_member "pagination_token" json;
      raw;
    }

let run ?endpoint:custom ~operation client request decode =
  let base_url = base_url (endpoint custom) in
  C.perform_json ~telemetry:`Provider ~base_url ~operation client request decode

let list_built_in ?endpoint client ~api_key =
  run ?endpoint ~operation:"list_voices" client
    (built_in_list_request ?endpoint ~api_key ())
    decode_built_ins

let get_built_in ?endpoint client ~api_key ~voice_id =
  run ?endpoint ~operation:"get_voice" client
    (built_in_get_request ?endpoint ~api_key ~voice_id ())
    (decode_one built_in)

let list_custom ?endpoint:custom_endpoint client ~api_key ?limit
    ?pagination_token () =
  let endpoint = endpoint custom_endpoint in
  let base_url = base_url endpoint in
  match
    custom_list_request ~endpoint ~api_key ?limit ?pagination_token ()
  with
  | Error error -> E.fail error
  | Ok request ->
      C.perform_json ~telemetry:`Provider ~base_url ~operation:"list_custom_voices" client request
        decode_custom_page

let get_custom ?endpoint client ~api_key ~voice_id =
  run ?endpoint ~operation:"get_custom_voice" client
    (custom_get_request ?endpoint ~api_key ~voice_id ())
    (decode_one custom)

let custom_audio ?endpoint:custom_endpoint client ~api_key ~voice_id =
  let endpoint = endpoint custom_endpoint in
  let base_url = base_url endpoint in
  C.perform_response ~telemetry:`Provider ~max_bytes:reference_audio_max_bytes ~base_url
    ~operation:"get_custom_voice_audio" client
    (custom_audio_request ~endpoint ~api_key ~voice_id ())
  |> E.map (fun (bytes, headers) ->
         { content_type = C.content_type headers; bytes })
