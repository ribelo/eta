open Types

let unsupported_result provider feature =
  Stdlib.Error (Unsupported { provider; feature })

let unsupported_embeddings provider =
  unsupported_result provider "embeddings"

let join_url base path =
  let base =
    if String.ends_with ~suffix:"/" base then
      String.sub base 0 (String.length base - 1)
    else base
  in
  let path = if String.starts_with ~prefix:"/" path then path else "/" ^ path in
  base ^ path

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

let read_response_body ?max_bytes body =
  Eta_http.Body.Stream.read_all ?max_bytes body
  |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Eta_http_error error))

let read_response_text ?max_bytes body =
  read_response_body ?max_bytes body |> Eta.Effect.map Bytes.to_string

let result_effect = function
  | Stdlib.Ok value -> Eta.Effect.pure value
  | Stdlib.Error error -> Eta.Effect.fail error

let submit_request client request =
  Eta_http.request client request
  |> Eta.Effect.suppress_observability
  |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Eta_http_error error))

let perform_raw ?max_bytes provider client request =
  submit_request client request
  |> Eta.Effect.bind (fun response ->
         if
           response.Eta_http.Response.status >= 200
           && response.status < 300
         then read_response_text ?max_bytes response.body
         else
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  Eta.Effect.fail
                    (provider.decode_error ~status:response.status
                       ~headers:response.headers raw)))

let perform_binary ?max_bytes provider client request =
  submit_request client request
  |> Eta.Effect.bind (fun response ->
         if
           response.Eta_http.Response.status >= 200
           && response.status < 300
         then
           read_response_body ?max_bytes response.body
           |> Eta.Effect.map (fun body -> (body, response.headers))
         else
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  Eta.Effect.fail
                    (provider.decode_error ~status:response.status
                       ~headers:response.headers raw)))

let perform_chat provider client request =
  submit_request client request
  |> Eta.Effect.bind (fun response ->
         if
           response.Eta_http.Response.status >= 200
           && response.status < 300
         then
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  result_effect (provider.decode_chat raw))
         else
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  Eta.Effect.fail
                    (provider.decode_error ~status:response.status
                       ~headers:response.headers raw)))

let perform_embeddings provider client request =
  submit_request client request
  |> Eta.Effect.bind (fun response ->
         if
           response.Eta_http.Response.status >= 200
           && response.status < 300
         then
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  result_effect (provider.decode_embeddings raw))
         else
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  Eta.Effect.fail
                    (provider.decode_error ~status:response.status
                       ~headers:response.headers raw)))


let perform_stream provider client request =
  submit_request client request
  |> Eta.Effect.bind (fun response ->
         if
           response.Eta_http.Response.status >= 200
           && response.status < 300
         then Eta.Effect.pure (Sse.stream_of_body provider response.body)
         else
           read_response_text response.body
           |> Eta.Effect.bind (fun raw ->
                  Eta.Effect.fail
                    (provider.decode_error ~status:response.status
                       ~headers:response.headers raw)))

