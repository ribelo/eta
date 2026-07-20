module A = Eta_ai
module Compat = Eta_ai_openai_compat
module Codec = Eta_ai_openai_codec
module Anthropic = Eta_ai_anthropic
module H = Eta_http
module Json = A.Json
module E = Eta.Effect

let provider_name = "kimi-coding"
let default_base_url = "https://api.kimi.com/coding/v1"
let default_oauth_host = "https://auth.kimi.com"
let client_id = "17e5f671-d194-4dfb-9706-5516cb48c098"
let default_platform = "kimi_code_cli"
let default_anthropic_version = "2023-06-01"
let default_messages_path = "/messages?beta=true"

type api_key_credential = A.api_key

type oauth_credential = {
  access_token : string Eta_redacted.t;
  refresh_token : string Eta_redacted.t;
  expires_at : int64;
  scope : string option;
  token_type : string option;
}

type credential = Api_key of api_key_credential | OAuth of oauth_credential

type device_identity = {
  platform : string;
  version : string;
  device_name : string option;
  device_model : string option;
  os_version : string option;
  device_id : string option;
}

type device_authorization = {
  user_code : string;
  device_code : string Eta_redacted.t;
  verification_uri : string;
  verification_uri_complete : string option;
  expires_in : int option;
  interval : int;
}

type device_poll_result =
  | Authorized of oauth_credential
  | Authorization_pending of { description : string option }
  | Slow_down of { interval : int; description : string option }
  | Expired of { description : string option }
  | Denied of { description : string option }

type protocol = Kimi | Anthropic
type supports_thinking_type = Only | No | Both

type think_efforts = {
  support : bool option;
  valid_efforts : string list;
  default_effort : string option;
}

type model_info = {
  id : string;
  display_name : string option;
  context_length : int option;
  supports_reasoning : bool option;
  supports_image_in : bool option;
  supports_video_in : bool option;
  supports_tool_use : bool option;
  supports_thinking_type : supports_thinking_type option;
  think_efforts : think_efforts option;
  protocol : protocol option;
}

type structured_output = Codec.structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let safe_error message =
  Codec.decode_error_result ~provider:provider_name message

let require_nonempty ~label value =
  if String.trim value = "" then safe_error (label ^ " is empty")
  else Stdlib.Ok (String.trim value)

let api_key value =
  match require_nonempty ~label:"api_key" value with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok value -> Stdlib.Ok (A.api_key value)

let oauth_credential ~access_token ~refresh_token ~expires_at ?scope ?token_type
    () =
  match require_nonempty ~label:"access_token" access_token with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok access_token -> (
      match require_nonempty ~label:"refresh_token" refresh_token with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok refresh_token ->
          if expires_at <= 0L then safe_error "expires_at must be positive"
          else
            Stdlib.Ok
              {
                access_token =
                  Eta_redacted.make ~label:"access_token" access_token;
                refresh_token =
                  Eta_redacted.make ~label:"refresh_token" refresh_token;
                expires_at;
                scope;
                token_type;
              })

let access_api_key (credential : credential) =
  match credential with
  | Api_key key -> key
  | OAuth oauth -> A.api_key (Eta_redacted.value oauth.access_token)

let credential_to_json = function
  | Api_key key ->
      Json.object_
        [
          ("type", Some (Json.string "api_key"));
          ("key", Some (Json.string (Eta_redacted.value key)));
        ]
  | OAuth oauth ->
      Json.object_
        [
          ("type", Some (Json.string "oauth"));
          ( "access_token",
            Some (Json.string (Eta_redacted.value oauth.access_token)) );
          ( "refresh_token",
            Some (Json.string (Eta_redacted.value oauth.refresh_token)) );
          ("expires_at", Some (`Intlit (Int64.to_string oauth.expires_at)));
          ("scope", Option.map Json.string oauth.scope);
          ("token_type", Option.map Json.string oauth.token_type);
        ]

let credential_to_string c = Json.to_string (credential_to_json c)

let int64_member name json =
  match Json.member name json with
  | Some (`Int i) -> Some (Int64.of_int i)
  | Some (`Intlit s) -> Int64.of_string_opt s
  | Some (`Float f) -> Some (Int64.of_float f)
  | _ -> None

let require_string_field json field =
  match Json.string_member field json with
  | Some value when String.trim value <> "" -> Stdlib.Ok (String.trim value)
  | Some _ | None -> safe_error (field ^ " missing")

let credential_of_json = function
  | `Assoc _ as json -> (
      match Json.string_member "type" json with
      | Some "oauth" -> (
          match require_string_field json "access_token" with
          | Stdlib.Error _ as e -> e
          | Stdlib.Ok access_token -> (
              match require_string_field json "refresh_token" with
              | Stdlib.Error _ as e -> e
              | Stdlib.Ok refresh_token -> (
                  match int64_member "expires_at" json with
                  | None -> safe_error "oauth credential missing expires_at"
                  | Some expires_at -> (
                      match
                        oauth_credential ~access_token ~refresh_token
                          ~expires_at
                          ?scope:(Json.string_member "scope" json)
                          ?token_type:(Json.string_member "token_type" json)
                          ()
                      with
                      | Stdlib.Error _ as e -> e
                      | Stdlib.Ok oauth -> Stdlib.Ok (OAuth oauth)))))
      | Some "api_key" -> (
          match require_string_field json "key" with
          | Stdlib.Error _ as e -> e
          | Stdlib.Ok key -> (
              match api_key key with
              | Stdlib.Error _ as e -> e
              | Stdlib.Ok key -> Stdlib.Ok (Api_key key)))
      | Some other -> safe_error ("unsupported credential type " ^ other)
      | None -> safe_error "credential missing type")
  | _ -> safe_error "credential must be a JSON object"

let credential_of_string raw =
  match Json.parse raw with
  | Stdlib.Error message -> safe_error message
  | Stdlib.Ok json -> credential_of_json json

let pp_credential fmt = function
  | Api_key key ->
      Format.fprintf fmt "@[<hov 2>{type=api_key;@ key=%a}@]" Eta_redacted.pp
        key
  | OAuth oauth ->
      Format.fprintf fmt
        "@[<hov 2>{type=oauth;@ access_token=%a;@ refresh_token=%a;@ \
         expires_at=%Ld}@]"
        Eta_redacted.pp oauth.access_token Eta_redacted.pp oauth.refresh_token
        oauth.expires_at

let device_identity ?(platform = default_platform) ~version ?device_name
    ?device_model ?os_version ?device_id () =
  { platform; version; device_name; device_model; os_version; device_id }

let identity_headers = function
  | None -> []
  | Some id ->
      let add name = function
        | None -> []
        | Some value when String.trim value <> "" -> [ (name, value) ]
        | Some _ -> []
      in
      ("X-Msh-Platform", id.platform)
      :: ("X-Msh-Version", id.version)
      :: add "X-Msh-Device-Name" id.device_name
      @ add "X-Msh-Device-Model" id.device_model
      @ add "X-Msh-Os-Version" id.os_version
      @ add "X-Msh-Device-Id" id.device_id

let auth_headers ?identity ?(extra_headers = []) credential =
  H.Core.Header.unsafe_of_list
    ([
       ( "Authorization",
         "Bearer " ^ Eta_redacted.value (access_api_key credential) );
       ("Content-Type", "application/json");
       ("Accept", "application/json");
     ]
    @ identity_headers identity @ extra_headers)

let messages_auth_headers ?identity
    ?(anthropic_version = default_anthropic_version) ?(extra_headers = [])
    credential =
  H.Core.Header.unsafe_of_list
    ([
       ( "Authorization",
         "Bearer " ^ Eta_redacted.value (access_api_key credential) );
       ("Content-Type", "application/json");
       ("Accept", "application/json");
       ("anthropic-version", anthropic_version);
     ]
    @ identity_headers identity @ extra_headers)

let trim_slash s =
  let s = String.trim s in
  if String.length s > 0 && s.[String.length s - 1] = '/' then
    String.sub s 0 (String.length s - 1)
  else s

let url_encode value =
  let buf = Buffer.create (String.length value * 2) in
  String.iter
    (fun c ->
      match c with
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' ->
          Buffer.add_char buf c
      | ' ' -> Buffer.add_string buf "%20"
      | _ -> Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c)))
    value;
  Buffer.contents buf

let form_body fields =
  fields
  |> List.map (fun (k, v) -> url_encode k ^ "=" ^ url_encode v)
  |> String.concat "&"

let form_request ~uri ?identity body =
  let headers =
    H.Core.Header.unsafe_of_list
      ([
         ("Content-Type", "application/x-www-form-urlencoded");
         ("Accept", "application/json");
       ]
      @ identity_headers identity)
  in
  H.Request.make ~headers
    ~body:(H.Request.Fixed [ Bytes.of_string body ])
    "POST" uri

let usable_http_url value =
  let value = String.trim value in
  String.length value > 0
  && (String.starts_with ~prefix:"https://" value
     || String.starts_with ~prefix:"http://" value)

let device_authorization_request ?(oauth_host = default_oauth_host)
    ?(client_id = client_id) ?identity () =
  form_request
    ~uri:(trim_slash oauth_host ^ "/api/oauth/device_authorization")
    ?identity
    (form_body [ ("client_id", client_id) ])

let decode_device_authorization raw =
  match Json.parse raw with
  | Stdlib.Error message -> safe_error message
  | Stdlib.Ok json -> (
      match require_string_field json "user_code" with
      | Stdlib.Error _ as e -> e
      | Stdlib.Ok user_code -> (
          match require_string_field json "device_code" with
          | Stdlib.Error _ as e -> e
          | Stdlib.Ok device_code -> (
              let verification_uri_complete =
                Json.string_member "verification_uri_complete" json
              in
              let verification_uri =
                match Json.string_member "verification_uri" json with
                | Some uri when usable_http_url uri -> Some uri
                | _ -> (
                    match verification_uri_complete with
                    | Some uri when usable_http_url uri -> Some uri
                    | _ -> None)
              in
              match verification_uri with
              | None ->
                  safe_error
                    "device authorization missing usable verification URL"
              | Some verification_uri ->
                  let expires_in = Json.int_member "expires_in" json in
                  let interval =
                    match Json.int_member "interval" json with
                    | Some i when i > 0 -> i
                    | _ -> 5
                  in
                  Stdlib.Ok
                    {
                      user_code;
                      device_code =
                        Eta_redacted.make ~label:"device_code" device_code;
                      verification_uri;
                      verification_uri_complete;
                      expires_in;
                      interval;
                    })))

let oauth_transport_provider =
  {
    A.name = provider_name;
    base_url = default_oauth_host;
    chat_path = "/api/oauth/token";
    embeddings_path = None;
    auth_headers =
      (fun _ ->
        H.Core.Header.unsafe_of_list
          [ ("Content-Type", "application/x-www-form-urlencoded") ]);
    capabilities =
      {
        A.streaming = false;
        tools = false;
        tool_choice = false;
        structured_outputs = false;
        text = false;
        image_input = false;
        audio_input = false;
        video_input = false;
        embeddings = false;
        image_generation = false;
        speech = false;
        transcription = false;
        rerank = false;
        video_generation = false;
      };
    encode_chat = (fun _ -> safe_error "no chat");
    decode_chat = (fun _ -> safe_error "no chat");
    encode_embeddings = (fun _ -> safe_error "no embeddings");
    decode_embeddings = (fun _ -> safe_error "no embeddings");
    decode_stream_event = (fun _ -> safe_error "no stream");
    decode_error =
      (fun ~status ~headers:_ _raw ->
        A.Provider_error
          {
            provider = provider_name;
            status = Some status;
            code = None;
            message = "kimi oauth error";
            raw = None;
            retry_after_s = None;
          });
  }

let run_raw client request decode =
  A.run_raw_decoded oauth_transport_provider client (Stdlib.Ok request) decode

let request_device_authorization ?oauth_host ?client_id ?identity client =
  run_raw client
    (device_authorization_request ?oauth_host ?client_id ?identity ())
    decode_device_authorization

let device_token_poll_request ?(oauth_host = default_oauth_host)
    ?(client_id = client_id) ?identity ~device_code () =
  form_request
    ~uri:(trim_slash oauth_host ^ "/api/oauth/token")
    ?identity
    (form_body
       [
         ("client_id", client_id);
         ("device_code", Eta_redacted.value device_code);
         ("grant_type", "urn:ietf:params:oauth:grant-type:device_code");
       ])

let oauth_from_token_json ~now_s json =
  match require_string_field json "access_token" with
  | Stdlib.Error _ as e -> e
  | Stdlib.Ok access_token -> (
      match require_string_field json "refresh_token" with
      | Stdlib.Error _ as e -> e
      | Stdlib.Ok refresh_token -> (
          match Json.int_member "expires_in" json with
          | Some expires_in when expires_in > 0 ->
              let expires_at = Int64.add now_s (Int64.of_int expires_in) in
              oauth_credential ~access_token ~refresh_token ~expires_at
                ?scope:(Json.string_member "scope" json)
                ?token_type:(Json.string_member "token_type" json)
                ()
          | Some _ | None -> safe_error "token response missing expires_in"))

let decode_token_response ?now_s raw =
  match now_s with
  | None -> safe_error "token decode requires now_s"
  | Some now_s -> (
      match Json.parse raw with
      | Stdlib.Error message -> safe_error message
      | Stdlib.Ok json -> oauth_from_token_json ~now_s json)

let error_description json =
  match Json.string_member "error_description" json with
  | Some _ as v -> v
  | None -> Json.string_member "message" json

let decode_device_poll ~status ?now_s ?(current_interval = 5) raw =
  match Json.parse raw with
  | Stdlib.Error message -> safe_error message
  | Stdlib.Ok json -> (
      if status >= 200 && status < 300 then
        match now_s with
        | None -> safe_error "authorized token decode requires now_s"
        | Some now_s -> (
            match oauth_from_token_json ~now_s json with
            | Stdlib.Ok oauth -> Stdlib.Ok (Authorized oauth)
            | Stdlib.Error _ as e -> e)
      else if status >= 500 then
        Stdlib.Error
          (A.Provider_error
             {
               provider = provider_name;
               status = Some status;
               code = None;
               message = "device token polling server error";
               raw = None;
               retry_after_s = None;
             })
      else
        let error_code =
          match Json.string_member "error" json with
          | Some code -> code
          | None -> "unknown_error"
        in
        let description = error_description json in
        match error_code with
        | "authorization_pending" ->
            Stdlib.Ok (Authorization_pending { description })
        | "slow_down" ->
            let interval =
              match Json.int_member "interval" json with
              | Some i when i > 0 -> i
              | _ -> max 1 (current_interval + 5)
            in
            Stdlib.Ok (Slow_down { interval; description })
        | "expired_token" -> Stdlib.Ok (Expired { description })
        | "access_denied" -> Stdlib.Ok (Denied { description })
        | other -> safe_error ("device token poll failed with " ^ other))

let read_body_text body =
  H.Body.Stream.read_all body
  |> E.map Bytes.unsafe_to_string
  |> E.catch (fun error -> E.fail (A.Eta_http_error error))

let poll_device_token ?oauth_host ?client_id ?identity ?now_s ?current_interval
    client ~device_code =
  let request =
    device_token_poll_request ?oauth_host ?client_id ?identity ~device_code ()
  in
  H.request client request
  |> E.catch (fun error -> E.fail (A.Eta_http_error error))
  |> E.bind (fun (response : H.Response.t) ->
         read_body_text response.body
         |> E.bind (fun raw ->
                match
                  decode_device_poll ~status:response.status ?now_s
                    ?current_interval raw
                with
                | Stdlib.Ok value -> E.pure value
                | Stdlib.Error error -> E.fail error))

let refresh_request ?(oauth_host = default_oauth_host) ?(client_id = client_id)
    ?identity credential =
  form_request
    ~uri:(trim_slash oauth_host ^ "/api/oauth/token")
    ?identity
    (form_body
       [
         ("client_id", client_id);
         ("grant_type", "refresh_token");
         ("refresh_token", Eta_redacted.value credential.refresh_token);
       ])

let refresh ?oauth_host ?client_id ?identity ?now_s client credential =
  match now_s with
  | None -> (
      match safe_error "refresh requires now_s" with
      | Stdlib.Error error -> E.fail error
      | Stdlib.Ok _ -> assert false)
  | Some now_s ->
      run_raw client
        (refresh_request ?oauth_host ?client_id ?identity credential)
        (decode_token_response ~now_s)

let protocol_to_string = function Kimi -> "kimi" | Anthropic -> "anthropic"

let protocol_of_string = function
  | "anthropic" -> Some Anthropic
  | "kimi" -> Some Kimi
  | _ -> None

let bool_member name json =
  match Json.member name json with Some (`Bool b) -> Some b | _ -> None

let parse_supports_thinking_type = function
  | Some "only" -> Some Only
  | Some "no" -> Some No
  | Some "both" -> Some Both
  | Some _ | None -> None

let parse_think_efforts = function
  | None -> None
  | Some json ->
      let valid_efforts =
        match Json.array_member "valid_efforts" json with
        | None -> []
        | Some items ->
            List.filter_map (function `String s -> Some s | _ -> None) items
      in
      Some
        {
          support = bool_member "support" json;
          valid_efforts;
          default_effort = Json.string_member "default_effort" json;
        }

let model_info_of_json json =
  match Json.string_member "id" json with
  | None | Some "" -> None
  | Some id ->
      Some
        {
          id;
          display_name =
            (match Json.string_member "display_name" json with
            | Some _ as v -> v
            | None -> Json.string_member "name" json);
          context_length = Json.int_member "context_length" json;
          supports_reasoning = bool_member "supports_reasoning" json;
          supports_image_in = bool_member "supports_image_in" json;
          supports_video_in = bool_member "supports_video_in" json;
          supports_tool_use = bool_member "supports_tool_use" json;
          supports_thinking_type =
            parse_supports_thinking_type
              (Json.string_member "supports_thinking_type" json);
          think_efforts =
            parse_think_efforts (Json.object_member "think_efforts" json);
          protocol =
            (match Json.string_member "protocol" json with
            | Some s -> protocol_of_string s
            | None -> None);
        }

let decode_models raw =
  match Json.parse raw with
  | Stdlib.Error message -> safe_error message
  | Stdlib.Ok json ->
      let items =
        match Json.array_member "data" json with
        | Some items -> items
        | None -> ( match json with `List items -> items | _ -> [])
      in
      let models = List.filter_map model_info_of_json items in
      if models = [] then safe_error "models catalog is empty"
      else Stdlib.Ok models

let structured_output = Compat.structured_output

let provider ?(base_url = default_base_url) ?identity ?(extra_headers = []) () =
  let p =
    Compat.provider ~name:provider_name ~base_url ~chat_path:"/chat/completions"
      ~extra_headers ()
  in
  {
    p with
    auth_headers =
      (fun key -> auth_headers ?identity ~extra_headers (Api_key key));
    capabilities =
      { p.capabilities with image_input = true; structured_outputs = true };
  }

let models_request ?provider:custom ?identity ~credential () =
  let provider =
    match custom with Some p -> p | None -> provider ?identity ()
  in
  let request =
    A.provider_get_request provider ~path:"/models" (access_api_key credential)
  in
  Stdlib.Ok { request with headers = auth_headers ?identity credential }

let list_models ?provider:custom ?identity client ~credential =
  let provider =
    match custom with Some p -> p | None -> provider ?identity ()
  in
  match models_request ~provider ?identity ~credential () with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok request ->
      A.run_raw_decoded provider client (Stdlib.Ok request) decode_models

let encode_chat = Compat.encode_chat
let decode_chat = Compat.decode_chat
let decode_stream_event = Compat.decode_stream_event
let decode_error = Compat.decode_error

let chat_completions_request ?structured_output ?provider:custom ?identity
    ~credential request =
  let provider =
    match custom with Some p -> p | None -> provider ?identity ()
  in
  match
    Compat.chat_completions_request ?structured_output ~provider
      ~api_key:(access_api_key credential)
      request
  with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok http_request ->
      Stdlib.Ok
        { http_request with headers = auth_headers ?identity credential }

let chat_completions ?structured_output ?provider:custom ?identity client
    ~credential request =
  let provider =
    match custom with Some p -> p | None -> provider ?identity ()
  in
  match
    chat_completions_request ?structured_output ~provider ?identity ~credential
      request
  with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider request
        (A.perform_chat provider client http_request)

let stream_chat_completions ?structured_output ?provider:custom ?identity client
    ~credential request =
  let provider =
    match custom with Some p -> p | None -> provider ?identity ()
  in
  let streamed = { request with A.stream = true } in
  match
    chat_completions_request ?structured_output ~provider ?identity ~credential
      streamed
  with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_stream_span provider streamed
        (A.perform_stream provider client http_request)

module Chat = struct
  let request = chat_completions_request
  let run = chat_completions
  let stream = stream_chat_completions
end

let messages_provider ?(base_url = default_base_url) ?identity
    ?(anthropic_version = default_anthropic_version) ?(extra_headers = []) () =
  let base = Anthropic.provider ~base_url () in
  {
    base with
    A.name = provider_name;
    base_url;
    chat_path = default_messages_path;
    auth_headers =
      (fun key ->
        messages_auth_headers ?identity ~anthropic_version ~extra_headers
          (Api_key key));
  }

let encode_messages request = Anthropic.encode_messages request
let decode_message raw = Anthropic.decode_message raw
let decode_messages_stream_event event = Anthropic.decode_stream_event event

let messages_request ?provider:custom ?identity
    ?(anthropic_version = default_anthropic_version) ~credential request =
  let provider =
    match custom with
    | Some p -> p
    | None -> messages_provider ?identity ~anthropic_version ()
  in
  match encode_messages request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      let http_request =
        A.provider_request provider (access_api_key credential) raw
      in
      Stdlib.Ok
        {
          http_request with
          headers =
            messages_auth_headers ?identity ~anthropic_version credential;
        }

let messages ?provider:custom ?identity ?anthropic_version client ~credential
    request =
  let provider =
    match custom with
    | Some p -> p
    | None -> messages_provider ?identity ?anthropic_version ()
  in
  match
    messages_request ~provider ?identity ?anthropic_version ~credential request
  with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider request
        (A.perform_chat provider client http_request)

let stream_messages ?provider:custom ?identity ?anthropic_version client
    ~credential request =
  let provider =
    match custom with
    | Some p -> p
    | None -> messages_provider ?identity ?anthropic_version ()
  in
  let streamed = { request with A.stream = true } in
  match
    messages_request ~provider ?identity ?anthropic_version ~credential streamed
  with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      let headers =
        messages_auth_headers ?identity ?anthropic_version credential
        |> H.Core.Header.remove "accept"
        |> H.Core.Header.unsafe_add "Accept" "text/event-stream"
      in
      let http_request = { http_request with headers } in
      A.with_stream_span provider streamed
        (A.perform_stream provider client http_request)

module Messages = struct
  let request = messages_request
  let run = messages
  let stream = stream_messages
end
