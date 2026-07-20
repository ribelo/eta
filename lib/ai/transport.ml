open Types

let unsupported_result provider feature =
  Stdlib.Error (Unsupported { provider; feature })

let unsupported_embeddings provider =
  unsupported_result provider "embeddings"

let trim_trailing_slash value =
  let len = String.length value in
  if len > 0 && Char.equal (String.unsafe_get value (len - 1)) '/' then
    String.sub value 0 (len - 1)
  else value

let join_url base path =
  let base_len = String.length base in
  let base_len =
    if base_len > 0 && Char.equal (String.unsafe_get base (base_len - 1)) '/'
    then base_len - 1
    else base_len
  in
  let path_len = String.length path in
  let path_start =
    if path_len > 0 && Char.equal (String.unsafe_get path 0) '/' then 1 else 0
  in
  let path_len = path_len - path_start in
  let out = Bytes.create (base_len + 1 + path_len) in
  Bytes.blit_string base 0 out 0 base_len;
  Bytes.unsafe_set out base_len '/';
  Bytes.blit_string path path_start out (base_len + 1) path_len;
  Bytes.unsafe_to_string out

let provider_post_request provider ~path api_key raw =
  let headers = provider.auth_headers api_key in
  Eta_http.Request.make ~headers
    ~body:(Eta_http.Request.Fixed [ Bytes.of_string raw ])
    "POST" (join_url provider.base_url path)

let provider_get_request provider ~path api_key =
  let headers = provider.auth_headers api_key in
  Eta_http.Request.make ~headers "GET" (join_url provider.base_url path)

let provider_request provider api_key raw =
  provider_post_request provider ~path:provider.chat_path api_key raw

let provider_embeddings_request provider api_key raw =
  match provider.embeddings_path with
  | Some path -> Stdlib.Ok (provider_post_request provider ~path api_key raw)
  | None -> unsupported_embeddings provider.name

let embeddings_request provider ~api_key request =
  match provider.encode_embeddings request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw -> provider_embeddings_request provider api_key raw

let request_from_raw raw build =
  match raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw -> Stdlib.Ok (build raw)

let post_request provider ~path ~api_key encode request =
  request_from_raw (encode request)
    (provider_post_request provider ~path api_key)

let get_request provider ~path ~api_key =
  Stdlib.Ok (provider_get_request provider ~path api_key)

let chat_request_from_raw provider ~api_key raw =
  request_from_raw raw (provider_request provider api_key)

let chat_request provider ~api_key encode request =
  chat_request_from_raw provider ~api_key (encode request)

let embeddings_request_with provider ~api_key encode request =
  match encode request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw -> provider_embeddings_request provider api_key raw

let read_response_body ?max_bytes body =
  Eta_http.Body.Stream.read_all ?max_bytes body
  |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Eta_http_error error))

let read_response_text ?max_bytes body =
  read_response_body ?max_bytes body |> Eta.Effect.map Bytes.unsafe_to_string

let result_effect = function
  | Stdlib.Ok value -> Eta.Effect.pure value
  | Stdlib.Error error -> Eta.Effect.fail error

let run_request request perform =
  match request with
  | Stdlib.Error error -> Eta.Effect.fail error
  | Stdlib.Ok http_request -> perform http_request

let submit_request client request =
  Eta_http.request client request
  |> Eta.Effect.suppress_observability
  |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Eta_http_error error))

let[@inline always] successful response =
  response.Eta_http.Response.status >= 200 && response.status < 300

let[@cold] fail_response ?max_bytes provider
    (response : Eta_http.Response.t) =
  read_response_text ?max_bytes response.Eta_http.Response.body
  |> Eta.Effect.bind (fun raw ->
         Eta.Effect.fail
           (provider.decode_error ~status:response.status
              ~headers:response.headers raw))

let[@inline always] submit_and_handle ?max_bytes provider client request
    on_success =
  submit_request client request
  |> Eta.Effect.bind (fun response ->
         if successful response then on_success response
         else fail_response ?max_bytes provider response)

let perform_raw ?max_bytes provider client request =
  submit_and_handle ?max_bytes provider client request (fun response ->
      read_response_text ?max_bytes response.body)

let perform_binary ?max_bytes provider client request =
  submit_and_handle ?max_bytes provider client request (fun response ->
      read_response_body ?max_bytes response.body
      |> Eta.Effect.map (fun body -> (body, response.headers)))

let[@inline always] perform_decoded provider decode client request =
  submit_and_handle provider client request (fun response ->
      read_response_text response.body
      |> Eta.Effect.bind (fun raw -> result_effect (decode raw)))

let perform_chat provider client request =
  perform_decoded provider provider.decode_chat client request

let perform_embeddings provider client request =
  perform_decoded provider provider.decode_embeddings client request

let perform_stream provider client request =
  submit_and_handle provider client request (fun response ->
      Eta.Effect.pure (Sse.stream_of_body provider response.body))

let run_chat_request provider client chat_request request =
  run_request request (fun http_request ->
      Observability.with_chat_span provider chat_request
        (perform_chat provider client http_request))

let run_stream_request provider client chat_request request =
  run_request request (fun http_request ->
      Observability.with_stream_span provider chat_request
        (perform_stream provider client http_request))

let run_embeddings_request provider client embedding_request request =
  run_request request (fun http_request ->
      Observability.with_embeddings_span provider embedding_request
        (perform_embeddings provider client http_request))

let decode_effect decode raw = result_effect (decode raw)

let run_raw_decoded ?max_bytes provider client request decode =
  run_request request (fun http_request ->
      perform_raw ?max_bytes provider client http_request
      |> Eta.Effect.bind (decode_effect decode))

let run_binary_decoded ?max_bytes provider client request decode =
  run_request request (fun http_request ->
      perform_binary ?max_bytes provider client http_request
      |> Eta.Effect.map decode)
