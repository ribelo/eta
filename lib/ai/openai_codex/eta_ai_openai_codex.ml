module A = Eta_ai
module Codec = Eta_ai_openai_codec
module H = Eta_http
module Json = A.Json
module E = Eta.Effect

let provider_name = "openai-codex"
let default_base_url = "https://chatgpt.com/backend-api/codex"
let default_issuer = "https://auth.openai.com"
let default_redirect_uri = "http://localhost:1455/auth/callback"
let client_id = "app_EMoamEEZ73f0CkXaXp7hrann"
let default_originator = "eta"
let jwt_auth_claim = "https://api.openai.com/auth"
let default_scope = "openid profile email offline_access"

type oauth_credential = {
  access_token : string Eta_redacted.t;
  refresh_token : string Eta_redacted.t;
  expires_at_ms : int64 option;
  account_id : string;
}

type structured_output = Codec.structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

type client_identity = { originator : string; user_agent : string }

type pkce = {
  code_verifier : string;
  code_challenge : string;
  code_challenge_method : string;
}

type authorize_plan = {
  authorize_url : string;
  redirect_uri : string;
  state : string;
  pkce : pkce;
  client_id : string;
  issuer : string;
}

type callback_input =
  | Callback_url of string
  | Callback_query of string
  | Callback_code of { code : string; state : string option }

type authorization_code = { code : string; state : string }

type token_set = {
  access_token : string Eta_redacted.t;
  refresh_token : string Eta_redacted.t;
  expires_in : int;
  id_token : string Eta_redacted.t option;
  account_id : string;
}

type model_info = {
  slug : string;
  display_name : string option;
  description : string option;
  supported_in_api : bool;
  priority : int option;
  default_reasoning_level : string option;
  supported_reasoning_levels : string list;
}

let safe_decode_error message =
  Codec.decode_error_result ~provider:provider_name message

let schema_value = Codec.schema_value ~provider:provider_name

let structured_output ?strict ~name ~schema_json () =
  Codec.structured_output ~schema_value ?strict ~name ~schema_json ()

let require_nonempty ~label value =
  if String.trim value = "" then safe_decode_error (label ^ " is empty")
  else Stdlib.Ok (String.trim value)

let oauth_credential ~access_token ~refresh_token ?expires_at_ms ~account_id ()
    =
  match require_nonempty ~label:"access_token" access_token with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok access_token -> (
      match require_nonempty ~label:"refresh_token" refresh_token with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok refresh_token -> (
          match require_nonempty ~label:"account_id" account_id with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok account_id ->
              Stdlib.Ok
                {
                  access_token =
                    Eta_redacted.make ~label:"access_token" access_token;
                  refresh_token =
                    Eta_redacted.make ~label:"refresh_token" refresh_token;
                  expires_at_ms;
                  account_id;
                }))

let access_api_key (credential : oauth_credential) =
  A.api_key (Eta_redacted.value credential.access_token)

let credential_to_json (credential : oauth_credential) =
  Json.object_
    [
      ("type", Some (Json.string "oauth"));
      ( "access_token",
        Some (Json.string (Eta_redacted.value credential.access_token)) );
      ( "refresh_token",
        Some (Json.string (Eta_redacted.value credential.refresh_token)) );
      ( "expires",
        match credential.expires_at_ms with
        | None -> None
        | Some ms -> Some (`Intlit (Int64.to_string ms)) );
      ("account_id", Some (Json.string credential.account_id));
    ]

let credential_to_string (credential : oauth_credential) =
  Json.to_string (credential_to_json credential)

let int64_member name json =
  match Json.member name json with
  | Some (`Int i) -> Some (Int64.of_int i)
  | Some (`Intlit s) -> Int64.of_string_opt s
  | Some (`Float f) -> Some (Int64.of_float f)
  | _ -> None

let require_string_field json field =
  match Json.string_member field json with
  | Some value when String.trim value <> "" -> Stdlib.Ok (String.trim value)
  | Some _ | None -> safe_decode_error (field ^ " missing from oauth credential")

let credential_of_json = function
  | `Assoc _ as json -> (
      match Json.string_member "type" json with
      | Some "oauth" -> (
          match require_string_field json "access_token" with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok access_token -> (
              match require_string_field json "refresh_token" with
              | Stdlib.Error _ as error -> error
              | Stdlib.Ok refresh_token -> (
                  match require_string_field json "account_id" with
                  | Stdlib.Error _ as error -> error
                  | Stdlib.Ok account_id -> (
                      let expires_at_ms =
                        match Json.member "expires" json with
                        | None -> Stdlib.Ok None
                        | Some _ -> (
                            match int64_member "expires" json with
                            | Some ms when ms > 0L -> Stdlib.Ok (Some ms)
                            | Some _ | None ->
                                safe_decode_error
                                  "oauth credential has malformed expires")
                      in
                      match expires_at_ms with
                      | Stdlib.Error _ as error -> error
                      | Stdlib.Ok expires_at_ms ->
                          oauth_credential ~access_token ~refresh_token
                            ?expires_at_ms ~account_id ()))))
      | Some other -> safe_decode_error ("unsupported credential type " ^ other)
      | None -> safe_decode_error "oauth credential missing type")
  | _ -> safe_decode_error "oauth credential must be a JSON object"

let credential_of_string raw =
  match Json.parse raw with
  | Stdlib.Error message -> safe_decode_error message
  | Stdlib.Ok json -> credential_of_json json

let pp_credential fmt (credential : oauth_credential) =
  Format.fprintf fmt
    "@[<hov 2>{type=oauth;@ access_token=%a;@ refresh_token=%a;@ expires=%a;@ \
     account_id=%s}@]"
    Eta_redacted.pp credential.access_token Eta_redacted.pp
    credential.refresh_token
    (fun fmt -> function
      | None -> Format.pp_print_string fmt "none"
      | Some ms -> Format.fprintf fmt "%Ld" ms)
    credential.expires_at_ms credential.account_id

let base64url_nopad bytes =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
    (Bytes.unsafe_to_string bytes)

let pkce_s256 ~code_verifier =
  match require_nonempty ~label:"code_verifier" code_verifier with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok code_verifier ->
      let digest = Sha256.digest_string code_verifier in
      Stdlib.Ok
        {
          code_verifier;
          code_challenge = base64url_nopad digest;
          code_challenge_method = "S256";
        }

let encode_entropy ~label ~min_bytes entropy =
  if String.length entropy < min_bytes then
    safe_decode_error
      (Printf.sprintf "%s requires at least %d entropy bytes" label min_bytes)
  else Stdlib.Ok (base64url_nopad (Bytes.of_string entropy))

let code_verifier_of_entropy entropy =
  encode_entropy ~label:"code_verifier" ~min_bytes:32 entropy

let state_of_entropy entropy =
  encode_entropy ~label:"oauth state" ~min_bytes:16 entropy

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

let trim_slash s =
  let s = String.trim s in
  if String.length s > 0 && s.[String.length s - 1] = '/' then
    String.sub s 0 (String.length s - 1)
  else s

let client_identity ?(originator = default_originator) ~user_agent () =
  { originator = String.trim originator; user_agent = String.trim user_agent }

let plan_authorize ?(issuer = default_issuer) ?(client_id = client_id)
    ?(redirect_uri = default_redirect_uri) ?(originator = default_originator)
    ~state ~code_verifier () =
  match require_nonempty ~label:"state" state with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok state -> (
      match pkce_s256 ~code_verifier with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok pkce ->
          let qs =
            [
              ("response_type", "code");
              ("client_id", client_id);
              ("redirect_uri", redirect_uri);
              ("scope", default_scope);
              ("code_challenge", pkce.code_challenge);
              ("code_challenge_method", pkce.code_challenge_method);
              ("id_token_add_organizations", "true");
              ("codex_cli_simplified_flow", "true");
              ("state", state);
              ("originator", originator);
            ]
            |> List.map (fun (k, v) -> k ^ "=" ^ url_encode v)
            |> String.concat "&"
          in
          Stdlib.Ok
            {
              authorize_url = trim_slash issuer ^ "/oauth/authorize?" ^ qs;
              redirect_uri;
              state;
              pkce;
              client_id;
              issuer;
            })

let split_query query =
  if query = "" then []
  else
    String.split_on_char '&' query
    |> List.filter_map (fun part ->
           match String.split_on_char '=' part with
           | [] | [ "" ] -> None
           | key :: rest ->
               let value = String.concat "=" rest in
               Some (key, value))

let percent_decode value =
  let buf = Buffer.create (String.length value) in
  let len = String.length value in
  let rec loop i =
    if i >= len then Buffer.contents buf
    else
      match value.[i] with
      | '+' ->
          Buffer.add_char buf ' ';
          loop (i + 1)
      | '%' when i + 2 < len -> (
          let hex = String.sub value (i + 1) 2 in
          match int_of_string_opt ("0x" ^ hex) with
          | Some code ->
              Buffer.add_char buf (Char.chr code);
              loop (i + 3)
          | None ->
              Buffer.add_char buf value.[i];
              loop (i + 1))
      | c ->
          Buffer.add_char buf c;
          loop (i + 1)
  in
  loop 0

let query_param params key =
  List.find_map
    (fun (k, v) -> if k = key then Some (percent_decode v) else None)
    params

let parse_authorization_callback ~expected_state input =
  match require_nonempty ~label:"expected_state" expected_state with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok expected_state -> (
      let params_of_query query = split_query query in
      let from_params params =
        match query_param params "error" with
        | Some error ->
            let description =
              match query_param params "error_description" with
              | Some d -> ": " ^ d
              | None -> ""
            in
            safe_decode_error ("oauth callback error " ^ error ^ description)
        | None -> (
            match query_param params "code" with
            | None | Some "" ->
                safe_decode_error "oauth callback missing authorization code"
            | Some code -> (
                match query_param params "state" with
                | None | Some "" ->
                    safe_decode_error "oauth callback missing state"
                | Some state when state <> expected_state ->
                    safe_decode_error "oauth callback state mismatch"
                | Some state -> Stdlib.Ok { code; state }))
      in
      match input with
      | Callback_code { code; state } -> (
          match require_nonempty ~label:"authorization code" code with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok code -> (
              match state with
              | None | Some "" ->
                  safe_decode_error "oauth callback missing state"
              | Some state when state <> expected_state ->
                  safe_decode_error "oauth callback state mismatch"
              | Some state -> Stdlib.Ok { code; state }))
      | Callback_query query -> from_params (params_of_query query)
      | Callback_url url -> (
          match String.index_opt url '?' with
          | None -> safe_decode_error "oauth callback URL missing query"
          | Some idx ->
              let query =
                String.sub url (idx + 1) (String.length url - idx - 1)
              in
              let query =
                match String.index_opt query '#' with
                | None -> query
                | Some hash -> String.sub query 0 hash
              in
              from_params (params_of_query query)))

let b64url_decode_nopad s =
  let padded =
    match String.length s mod 4 with 2 -> s ^ "==" | 3 -> s ^ "=" | _ -> s
  in
  try
    Some (Base64.decode_exn ~pad:true ~alphabet:Base64.uri_safe_alphabet padded)
  with _ -> ( try Some (Base64.decode_exn ~pad:true padded) with _ -> None)

let account_id_of_jwt token =
  match String.split_on_char '.' token with
  | [ _; payload; _ ] -> (
      match b64url_decode_nopad payload with
      | None -> None
      | Some json_text -> (
          match Json.parse json_text with
          | Stdlib.Error _ -> None
          | Stdlib.Ok json -> (
              match Json.object_member jwt_auth_claim json with
              | Some auth -> Json.string_member "chatgpt_account_id" auth
              | None -> Json.string_member "chatgpt_account_id" json)))
  | _ -> None

let form_body fields =
  fields
  |> List.map (fun (k, v) -> url_encode k ^ "=" ^ url_encode v)
  |> String.concat "&"

let token_endpoint issuer = trim_slash issuer ^ "/oauth/token"

let form_request ~uri body =
  let headers =
    H.Core.Header.unsafe_of_list
      [
        ("Content-Type", "application/x-www-form-urlencoded");
        ("Accept", "application/json");
      ]
  in
  H.Request.make ~headers
    ~body:(H.Request.Fixed [ Bytes.of_string body ])
    "POST" uri

let exchange_code_request ?(issuer = default_issuer) ?(client_id = client_id)
    ~redirect_uri ~code ~code_verifier () =
  form_request ~uri:(token_endpoint issuer)
    (form_body
       [
         ("grant_type", "authorization_code");
         ("client_id", client_id);
         ("code", code);
         ("code_verifier", code_verifier);
         ("redirect_uri", redirect_uri);
       ])

let refresh_request ?(issuer = default_issuer) ?(client_id = client_id)
    (credential : oauth_credential) =
  form_request ~uri:(token_endpoint issuer)
    (form_body
       [
         ("grant_type", "refresh_token");
         ("refresh_token", Eta_redacted.value credential.refresh_token);
         ("client_id", client_id);
       ])

let decode_token_response raw =
  match Json.parse raw with
  | Stdlib.Error message -> safe_decode_error message
  | Stdlib.Ok json -> (
      match require_string_field json "access_token" with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok access_token -> (
          match require_string_field json "refresh_token" with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok refresh_token -> (
              match Json.int_member "expires_in" json with
              | Some expires_in when expires_in > 0 -> (
                  let id_token = Json.string_member "id_token" json in
                  let account_id =
                    match
                      List.find_map
                        (fun token -> account_id_of_jwt token)
                        (access_token
                        ::
                        (match id_token with
                        | Some token -> [ token ]
                        | None -> []))
                    with
                    | Some id when String.trim id <> "" -> Some (String.trim id)
                    | Some _ | None -> None
                  in
                  match account_id with
                  | None ->
                      safe_decode_error
                        "token response missing chatgpt_account_id"
                  | Some account_id ->
                      Stdlib.Ok
                        {
                          access_token =
                            Eta_redacted.make ~label:"access_token" access_token;
                          refresh_token =
                            Eta_redacted.make ~label:"refresh_token"
                              refresh_token;
                          expires_in;
                          id_token =
                            Option.map
                              (Eta_redacted.make ~label:"id_token")
                              id_token;
                          account_id;
                        })
              | Some _ | None ->
                  safe_decode_error "token response missing expires_in")))

let credential_of_token_set ~now_ms (token : token_set) : oauth_credential =
  {
    access_token = token.access_token;
    refresh_token = token.refresh_token;
    expires_at_ms =
      Some (Int64.add now_ms (Int64.mul (Int64.of_int token.expires_in) 1000L));
    account_id = token.account_id;
  }

let oauth_http_error ~status raw =
  match Json.parse raw with
  | Stdlib.Ok json ->
      let code =
        match Json.string_member "error" json with
        | Some c when String.trim c <> "" -> Some (String.trim c)
        | Some _ | None -> None
      in
      let message =
        match Json.string_member "error_description" json with
        | Some d when String.trim d <> "" -> String.trim d
        | Some _ | None -> (
            match Json.string_member "message" json with
            | Some m when String.trim m <> "" -> String.trim m
            | Some _ | None -> "oauth token endpoint error")
      in
      A.Provider_error
        {
          provider = provider_name;
          status = Some status;
          code;
          message;
          raw = None;
          retry_after_s = None;
        }
  | Stdlib.Error _ ->
      A.Provider_error
        {
          provider = provider_name;
          status = Some status;
          code = None;
          message = "oauth token endpoint error";
          raw = None;
          retry_after_s = None;
        }

let oauth_provider =
  {
    A.name = provider_name;
    base_url = default_issuer;
    chat_path = "/oauth/token";
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
    encode_chat = (fun _ -> safe_decode_error "oauth provider has no chat");
    decode_chat = (fun _ -> safe_decode_error "oauth provider has no chat");
    encode_embeddings =
      (fun _ -> safe_decode_error "oauth provider has no embeddings");
    decode_embeddings =
      (fun _ -> safe_decode_error "oauth provider has no embeddings");
    decode_stream_event =
      (fun _ -> safe_decode_error "oauth provider has no stream");
    decode_error = (fun ~status ~headers:_ raw -> oauth_http_error ~status raw);
  }

let read_body_text body =
  H.Body.Stream.read_all body
  |> E.map Bytes.unsafe_to_string
  |> E.bind_error (fun error -> E.fail (A.Eta_http_error error))

let run_token_request client request =
  H.request client request
  |> E.bind_error (fun error -> E.fail (A.Eta_http_error error))
  |> E.bind (fun (response : H.Response.t) ->
         read_body_text response.body
         |> E.bind (fun raw ->
                if response.status >= 200 && response.status < 300 then
                  match decode_token_response raw with
                  | Stdlib.Ok token -> E.pure token
                  | Stdlib.Error error -> E.fail error
                else E.fail (oauth_http_error ~status:response.status raw)))

let exchange_code ?issuer ?client_id client ~redirect_uri ~code ~code_verifier
    ~now_ms =
  run_token_request client
    (exchange_code_request ?issuer ?client_id ~redirect_uri ~code ~code_verifier
       ())
  |> E.map (fun token -> credential_of_token_set ~now_ms token)

let refresh ?issuer ?client_id client credential ~now_ms =
  run_token_request client (refresh_request ?issuer ?client_id credential)
  |> E.map (fun token -> credential_of_token_set ~now_ms token)

let auth_headers ~identity ?session_id ?(stream = false) ?(extra_headers = [])
    ~account_id ~access_token () =
  let base =
    [
      ("Authorization", "Bearer " ^ Eta_redacted.value access_token);
      ("Content-Type", "application/json");
      ("Accept", if stream then "text/event-stream" else "application/json");
      ("OpenAI-Beta", "responses=experimental");
      ("originator", identity.originator);
      ("User-Agent", identity.user_agent);
      ("ChatGPT-Account-ID", account_id);
    ]
  in
  let with_session =
    match session_id with
    | Some id when String.trim id <> "" ->
        ("session-id", id) :: ("x-client-request-id", id) :: base
    | Some _ | None -> base
  in
  (* Auth/security headers win over caller extras with the same name. *)
  let extras =
    List.filter
      (fun (name, _) ->
        let n = String.lowercase_ascii name in
        n <> "authorization" && n <> "chatgpt-account-id" && n <> "openai-beta"
        && n <> "content-type" && n <> "accept" && n <> "user-agent"
        && n <> "originator" && n <> "session-id" && n <> "x-client-request-id")
      extra_headers
  in
  H.Core.Header.unsafe_of_list (with_session @ extras)

let auth_headers_of_credential ~identity ?session_id ?stream ?extra_headers
    (credential : oauth_credential) =
  auth_headers ~identity ?session_id ?stream ?extra_headers
    ~account_id:credential.account_id
    ~access_token:(access_api_key credential)
    ()

let encode_responses ?structured_output request =
  Codec.encode_responses ~provider:provider_name ~schema_value
    ?structured_output request

let decode_responses raw = Codec.decode_responses ~provider:provider_name raw

let decode_stream_event event =
  Codec.decode_stream_event ~provider:provider_name event

let decode_error ~status ~headers raw =
  Codec.decode_error ~provider:provider_name ~status ~headers raw

let capabilities =
  {
    A.streaming = true;
    tools = true;
    tool_choice = true;
    structured_outputs = true;
    text = true;
    image_input = true;
    audio_input = false;
    video_input = false;
    embeddings = false;
    image_generation = false;
    speech = false;
    transcription = false;
    rerank = false;
    video_generation = false;
  }

let provider ?(base_url = default_base_url) ~account_id ~identity ?session_id
    ?(extra_headers = []) () =
  {
    A.name = provider_name;
    base_url;
    chat_path = "/responses";
    embeddings_path = None;
    auth_headers =
      (fun api_key ->
        auth_headers ~identity ?session_id ~extra_headers ~account_id
          ~access_token:api_key ());
    capabilities;
    encode_chat = (fun request -> encode_responses request);
    decode_chat = decode_responses;
    encode_embeddings =
      (fun _ ->
        Stdlib.Error
          (A.Unsupported { provider = provider_name; feature = "embeddings" }));
    decode_embeddings =
      (fun _ ->
        Stdlib.Error
          (A.Unsupported { provider = provider_name; feature = "embeddings" }));
    decode_stream_event;
    decode_error;
  }

let provider_for_credential ?base_url ~identity ?session_id ?extra_headers
    (credential : oauth_credential) =
  provider ?base_url ~account_id:credential.account_id ~identity ?session_id
    ?extra_headers ()

let reasoning_levels_member name json =
  match Json.array_member name json with
  | None -> []
  | Some items ->
      List.filter_map
        (fun item ->
          match item with
          | `String s when String.trim s <> "" -> Some (String.trim s)
          | `Assoc _ -> (
              match Json.string_member "effort" item with
              | Some s when String.trim s <> "" -> Some (String.trim s)
              | Some _ | None -> None)
          | _ -> None)
        items

let model_info_of_json json =
  match Json.string_member "slug" json with
  | None | Some "" -> None
  | Some slug ->
      Some
        {
          slug;
          display_name = Json.string_member "display_name" json;
          description = Json.string_member "description" json;
          supported_in_api =
            (match Json.member "supported_in_api" json with
            | Some (`Bool b) -> b
            | _ -> false);
          priority = Json.int_member "priority" json;
          default_reasoning_level =
            (match Json.string_member "default_reasoning_level" json with
            | Some _ as v -> v
            | None ->
                Option.bind
                  (Json.object_member "default_reasoning_level" json)
                  (Json.string_member "effort"));
          supported_reasoning_levels =
            reasoning_levels_member "supported_reasoning_levels" json;
        }

let decode_models raw =
  match Json.parse raw with
  | Stdlib.Error message -> safe_decode_error message
  | Stdlib.Ok json -> (
      match Json.array_member "models" json with
      | None -> safe_decode_error "models catalog missing models array"
      | Some items ->
          let models = List.filter_map model_info_of_json items in
          if models = [] then safe_decode_error "models catalog is empty"
          else Stdlib.Ok models)

let models_request ?provider:custom ?(client_version = "0.0.0") ~identity
    ~credential () =
  let provider =
    match custom with
    | Some p -> p
    | None -> provider_for_credential ~identity credential
  in
  let path =
    if String.trim client_version = "" then "/models"
    else "/models?client_version=" ^ url_encode client_version
  in
  let request =
    A.provider_get_request provider ~path (access_api_key credential)
  in
  Stdlib.Ok request

let list_models ?provider:custom ?client_version ~identity client ~credential =
  let provider =
    match custom with
    | Some p -> p
    | None -> provider_for_credential ~identity credential
  in
  match models_request ~provider ?client_version ~identity ~credential () with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok request ->
      A.run_raw_decoded provider client (Stdlib.Ok request) decode_models

let responses_request ?structured_output ?provider:custom ~identity ?session_id
    ~credential request =
  let provider =
    match custom with
    | Some p -> p
    | None -> provider_for_credential ~identity ?session_id credential
  in
  match encode_responses ?structured_output request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      let http_request =
        A.provider_request provider (access_api_key credential) raw
      in
      let headers = provider.auth_headers (access_api_key credential) in
      let headers =
        if request.A.stream then
          headers
          |> H.Core.Header.remove "accept"
          |> H.Core.Header.unsafe_add "Accept" "text/event-stream"
        else headers
      in
      Stdlib.Ok { http_request with headers }

let responses ?structured_output ?provider:custom ~identity ?session_id client
    ~credential request =
  let provider =
    match custom with
    | Some p -> p
    | None -> provider_for_credential ~identity ?session_id credential
  in
  match
    responses_request ?structured_output ~provider ~identity ?session_id
      ~credential request
  with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider request
        (A.perform_chat provider client http_request)

let stream_responses ?structured_output ?provider:custom ~identity ?session_id
    client ~credential request =
  let provider =
    match custom with
    | Some p -> p
    | None -> provider_for_credential ~identity ?session_id credential
  in
  let streamed = { request with A.stream = true } in
  match
    responses_request ?structured_output ~provider ~identity ?session_id
      ~credential streamed
  with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_stream_span provider streamed
        (A.perform_stream provider client http_request)

module Chat = struct
  let request = responses_request
  let run = responses
  let stream = stream_responses
end
