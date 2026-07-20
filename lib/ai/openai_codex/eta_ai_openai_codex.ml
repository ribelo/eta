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
  account_id : string option;
}

type structured_output = Codec.structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let decode_error_result ?raw message =
  Codec.decode_error_result ?raw ~provider:provider_name message

let schema_value = Codec.schema_value ~provider:provider_name

let structured_output ?strict ~name ~schema_json () =
  Codec.structured_output ~schema_value ?strict ~name ~schema_json ()

let redacted_token ~label value = Eta_redacted.make ~label value

let oauth_credential ~access_token ~refresh_token ?expires_at_ms ?account_id ()
    =
  {
    access_token = redacted_token ~label:"access_token" access_token;
    refresh_token = redacted_token ~label:"refresh_token" refresh_token;
    expires_at_ms;
    account_id;
  }

let access_api_key credential =
  A.api_key (Eta_redacted.value credential.access_token)

let credential_to_json credential =
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
      ("account_id", Option.map Json.string credential.account_id);
    ]

let credential_to_string credential =
  Json.to_string (credential_to_json credential)

let require_string_field json field =
  match Json.string_member field json with
  | Some value when String.trim value <> "" -> Stdlib.Ok value
  | Some _ | None ->
      decode_error_result ~raw:(Json.to_string json)
        (field ^ " missing from oauth credential")

let credential_of_json json =
  match json with
  | `Assoc _ -> (
      match require_string_field json "access_token" with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok access_token -> (
          match require_string_field json "refresh_token" with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok refresh_token ->
              let expires_at_ms =
                match Json.member "expires" json with
                | Some (`Int i) -> Some (Int64.of_int i)
                | Some (`Intlit s) -> (
                    match Int64.of_string_opt s with
                    | Some v -> Some v
                    | None -> None)
                | Some (`Float f) -> Some (Int64.of_float f)
                | _ -> None
              in
              let account_id = Json.string_member "account_id" json in
              Stdlib.Ok
                (oauth_credential ~access_token ~refresh_token ?expires_at_ms
                   ?account_id ())))
  | _ ->
      decode_error_result ~raw:(Json.to_string json)
        "oauth credential must be an object"

let credential_of_string raw =
  match Json.parse raw with
  | Stdlib.Error message -> decode_error_result ~raw message
  | Stdlib.Ok json -> credential_of_json json

let pp_credential fmt credential =
  Format.fprintf fmt
    "@[<hov 2>{type=oauth;@ access_token=%a;@ refresh_token=%a;@ expires=%a;@ \
     account_id=%a}@]"
    Eta_redacted.pp credential.access_token Eta_redacted.pp
    credential.refresh_token
    (fun fmt -> function
      | None -> Format.pp_print_string fmt "none"
      | Some ms -> Format.fprintf fmt "%Ld" ms)
    credential.expires_at_ms
    (fun fmt -> function
      | None -> Format.pp_print_string fmt "none"
      | Some id -> Format.pp_print_string fmt id)
    credential.account_id

type pkce = {
  code_verifier : string;
  code_challenge : string;
  code_challenge_method : string;
}

let base64url_nopad bytes =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
    (Bytes.unsafe_to_string bytes)

let pkce_s256 ~code_verifier =
  let digest = Sha256.digest_string code_verifier in
  {
    code_verifier;
    code_challenge = base64url_nopad digest;
    code_challenge_method = "S256";
  }

let generate_code_verifier ?(nbytes = 32) rng =
  let buf = Bytes.create nbytes in
  for i = 0 to nbytes - 1 do
    Bytes.set buf i (Char.chr (rng () land 0xff))
  done;
  base64url_nopad buf

let default_rng =
  let state = Random.State.make_self_init () in
  fun () -> Random.State.bits state land 0xff

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

type authorize_plan = {
  authorize_url : string;
  redirect_uri : string;
  state : string;
  pkce : pkce;
  client_id : string;
  issuer : string;
}

let plan_authorize ?(issuer = default_issuer) ?(client_id = client_id)
    ?(redirect_uri = default_redirect_uri) ?(originator = default_originator)
    ?state ?code_verifier ?(rng = default_rng) () =
  let state =
    match state with
    | Some state -> state
    | None -> generate_code_verifier ~nbytes:16 rng
  in
  let code_verifier =
    match code_verifier with
    | Some verifier -> verifier
    | None -> generate_code_verifier ~nbytes:32 rng
  in
  let pkce = pkce_s256 ~code_verifier in
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
  let authorize_url =
    let base =
      String.trim issuer |> fun s ->
      if String.length s > 0 && s.[String.length s - 1] = '/' then
        String.sub s 0 (String.length s - 1)
      else s
    in
    base ^ "/oauth/authorize?" ^ qs
  in
  { authorize_url; redirect_uri; state; pkce; client_id; issuer }

type token_set = {
  access_token : string;
  refresh_token : string;
  expires_in : int option;
  id_token : string option;
}

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

let credential_of_token_set ?now_ms token =
  let expires_at_ms =
    match (token.expires_in, now_ms) with
    | Some seconds, Some now ->
        Some (Int64.add now (Int64.mul (Int64.of_int seconds) 1000L))
    | Some _, None | None, _ -> None
  in
  let account_id =
    match token.id_token with
    | Some id_token -> account_id_of_jwt id_token
    | None -> account_id_of_jwt token.access_token
  in
  oauth_credential ~access_token:token.access_token
    ~refresh_token:token.refresh_token ?expires_at_ms ?account_id ()

let form_body fields =
  fields
  |> List.map (fun (k, v) -> url_encode k ^ "=" ^ url_encode v)
  |> String.concat "&"

let token_endpoint issuer =
  let base =
    let s = String.trim issuer in
    if String.length s > 0 && s.[String.length s - 1] = '/' then
      String.sub s 0 (String.length s - 1)
    else s
  in
  base ^ "/oauth/token"

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
  let body =
    form_body
      [
        ("grant_type", "authorization_code");
        ("client_id", client_id);
        ("code", code);
        ("code_verifier", code_verifier);
        ("redirect_uri", redirect_uri);
      ]
  in
  form_request ~uri:(token_endpoint issuer) body

let refresh_request ?(issuer = default_issuer) ?(client_id = client_id)
    ~refresh_token () =
  let body =
    form_body
      [
        ("grant_type", "refresh_token");
        ("refresh_token", refresh_token);
        ("client_id", client_id);
      ]
  in
  form_request ~uri:(token_endpoint issuer) body

let decode_token_response raw =
  match Json.parse raw with
  | Stdlib.Error message -> decode_error_result ~raw message
  | Stdlib.Ok json -> (
      match require_string_field json "access_token" with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok access_token -> (
          match require_string_field json "refresh_token" with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok refresh_token ->
              let expires_in = Json.int_member "expires_in" json in
              let id_token = Json.string_member "id_token" json in
              Stdlib.Ok { access_token; refresh_token; expires_in; id_token }))

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
    encode_chat = (fun _ -> decode_error_result "oauth provider has no chat");
    decode_chat = (fun _ -> decode_error_result "oauth provider has no chat");
    encode_embeddings =
      (fun _ -> decode_error_result "oauth provider has no embeddings");
    decode_embeddings =
      (fun _ -> decode_error_result "oauth provider has no embeddings");
    decode_stream_event =
      (fun _ -> decode_error_result "oauth provider has no stream");
    decode_error =
      (fun ~status ~headers:_ raw ->
        A.Provider_error
          {
            provider = provider_name;
            status = Some status;
            code = None;
            message = "oauth token endpoint error";
            raw = Some raw;
            retry_after_s = None;
          });
  }

let run_token_request client request =
  A.run_raw_decoded oauth_provider client (Stdlib.Ok request)
    decode_token_response

let exchange_code ?issuer ?client_id client ~redirect_uri ~code ~code_verifier =
  let request =
    exchange_code_request ?issuer ?client_id ~redirect_uri ~code ~code_verifier
      ()
  in
  run_token_request client request

let refresh ?issuer ?client_id client ~refresh_token =
  let request = refresh_request ?issuer ?client_id ~refresh_token () in
  run_token_request client request

let auth_headers ?(originator = default_originator) ?session_id ?account_id
    ?(extra_headers = []) ~access_token () =
  let base =
    [
      ("Authorization", "Bearer " ^ Eta_redacted.value access_token);
      ("Content-Type", "application/json");
      ("Accept", "application/json");
      ("OpenAI-Beta", "responses=experimental");
      ("originator", originator);
    ]
  in
  let with_account =
    match account_id with
    | Some id when String.trim id <> "" -> ("ChatGPT-Account-ID", id) :: base
    | Some _ | None -> base
  in
  let with_session =
    match session_id with
    | Some id when String.trim id <> "" ->
        ("session_id", id) :: ("conversation_id", id) :: with_account
    | Some _ | None -> with_account
  in
  H.Core.Header.unsafe_of_list (with_session @ extra_headers)

let auth_headers_of_credential ?originator ?session_id ?extra_headers credential
    =
  auth_headers ?originator ?session_id ?account_id:credential.account_id
    ?extra_headers
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

let provider ?(base_url = default_base_url) ?account_id
    ?(originator = default_originator) ?session_id ?(extra_headers = []) () =
  {
    A.name = provider_name;
    base_url;
    chat_path = "/responses";
    embeddings_path = None;
    auth_headers =
      (fun api_key ->
        auth_headers ~originator ?session_id ?account_id ~extra_headers
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

let provider_for_credential ?base_url ?originator ?session_id ?extra_headers
    credential =
  provider ?base_url ?account_id:credential.account_id ?originator ?session_id
    ?extra_headers ()

let default_provider custom =
  match custom with Some p -> p | None -> provider ()

let responses_request ?structured_output ?provider:custom ~credential request =
  let provider =
    match custom with Some p -> p | None -> provider_for_credential credential
  in
  match encode_responses ?structured_output request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok (A.provider_request provider (access_api_key credential) raw)

let models_request ?provider:custom ?(client_version = "0.0.0") ~credential () =
  let provider =
    match custom with Some p -> p | None -> provider_for_credential credential
  in
  let path =
    if String.trim client_version = "" then "/models"
    else "/models?client_version=" ^ url_encode client_version
  in
  Stdlib.Ok (A.provider_get_request provider ~path (access_api_key credential))

let responses ?structured_output ?provider:custom client ~credential request =
  let provider =
    match custom with Some p -> p | None -> provider_for_credential credential
  in
  A.run_chat_request provider client request
    (responses_request ?structured_output ~provider ~credential request)

let stream_responses ?structured_output ?provider:custom client ~credential
    request =
  let provider =
    match custom with Some p -> p | None -> provider_for_credential credential
  in
  let streamed = { request with A.stream = true } in
  A.run_stream_request provider client streamed
    (responses_request ?structured_output ~provider ~credential streamed)

module Chat = struct
  let request = responses_request
  let run = responses
  let stream = stream_responses
end
