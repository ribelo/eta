(** In-process Eta server lifecycle for testsuite server-mode runs. *)

open Types

type t = Eta_http_eio.Server.t

let echo_trace_path =
  lazy
    (match Sys.getenv_opt "ETA_HTTP_ECHO_TRACE_PATH" with
    | Some _ as path -> path
    | None -> Sys.getenv_opt "ETA_H2_ECHO_TRACE_PATH")
let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.0)

let trace_echo_line line =
  match Lazy.force echo_trace_path with
  | None -> ()
  | Some path ->
      let out =
        open_out_gen [ Open_creat; Open_append; Open_text ] 0o644 path
      in
      Fun.protect
        ~finally:(fun () -> close_out_noerr out)
        (fun () ->
          output_string out line;
          output_char out '\n')

let header_list entries =
  match Eta_http.Core.Header.of_list entries with
  | Ok headers -> headers
  | Error _ -> invalid_arg "Eta_server.header_list: invalid fixture header"

let text ?(status = 200) ?(headers = []) body =
  Eta_http.Server.Response.text ~status ~headers:(header_list headers) body

let empty ?(headers = []) status =
  Eta_http.Server.Response.empty ~status ~headers:(header_list headers) ()

let fixed ?(status = 200) ?(headers = []) body =
  Eta_http.Server.Response.make ~status ~headers:(header_list headers)
    ~body:(Eta_http.Server.Response.Body.string body)
    ()

let redirect status =
  empty ~headers:[ ("location", "/healthz") ] status

let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () ->
      let len = in_channel_length input in
      really_input_string input len)

let static_response ~temp_dir path =
  let prefix = "/static/" in
  if not (String.starts_with ~prefix path) then None
  else
    let name =
      String.sub path (String.length prefix)
        (String.length path - String.length prefix)
    in
    let file = Filename.concat temp_dir name in
    if Sys.file_exists file then Some (fixed (read_file file)) else None

let status_response = function
  | "/status204" -> Some (empty 204)
  | "/status206" -> Some (text ~status:206 "partial")
  | "/status400" -> Some (empty 400)
  | "/status401" -> Some (empty 401)
  | "/status413" -> Some (empty 413)
  | "/status429" -> Some (empty 429)
  | "/status500" -> Some (empty 500)
  | "/status502" -> Some (empty 502)
  | "/status503" -> Some (empty 503)
  | "/status504" -> Some (empty 504)
  | _ -> None

let redirect_response = function
  | "/redirect301" -> Some (redirect 301)
  | "/redirect302" -> Some (redirect 302)
  | "/redirect307" -> Some (redirect 307)
  | "/redirect308" -> Some (redirect 308)
  | _ -> None

let user_id_response path =
  let prefix = "/user/" in
  if String.starts_with ~prefix path then
    Some (text (String.sub path (String.length prefix)
                  (String.length path - String.length prefix)))
  else None

let echo_response request =
  let started_us = now_us () in
  Eta_http.Server.Body.read_all request.Eta_http.Server.Request.body
  |> Eta.Effect.map (fun body ->
         let body_available_us = now_us () in
         let body_us = body_available_us - started_us in
         let body_len = Bytes.length body in
         let response = Bytes.to_string body in
         let response_len = String.length response in
         let request_id = Lazy.force request.Eta_http.Server.Request.id in
         let stream_id =
           Option.value request.Eta_http.Server.Request.stream_id ~default:(-1)
         in
         trace_echo_line
           (Printf.sprintf
              "echo_handler request_id=%s connection_id=%s stream_id=%d \
               handler_started_us=%d body_available_us=%d \
               request_body_read_us=%d body_bytes=%d response_bytes=%d \
               handler_copy_bytes=%d"
              request_id request.connection_id stream_id started_us
              body_available_us body_us body_len response_len (body_len * 2));
         fixed ~headers:[ ("content-type", "text/plain") ] response)
  |> Eta.Effect.bind_error (fun _error -> Eta.Effect.pure (empty 500))

let echo_once_response request =
  let started_us = now_us () in
  Eta_http.Server.Body.read request.Eta_http.Server.Request.body
  |> Eta.Effect.map (fun body ->
         let body_available_us = now_us () in
         let body_us = body_available_us - started_us in
         let body =
           match body with
           | None -> Bytes.empty
           | Some chunk -> chunk
         in
         let body_len = Bytes.length body in
         let response = Bytes.to_string body in
         let response_len = String.length response in
         let request_id = Lazy.force request.Eta_http.Server.Request.id in
         let stream_id =
           Option.value request.Eta_http.Server.Request.stream_id ~default:(-1)
         in
         trace_echo_line
           (Printf.sprintf
              "echo_once_handler request_id=%s connection_id=%s stream_id=%d \
               handler_started_us=%d body_available_us=%d \
               request_body_read_us=%d body_bytes=%d response_bytes=%d \
               handler_copy_bytes=%d"
              request_id request.connection_id stream_id started_us
              body_available_us body_us body_len response_len (body_len * 2));
         fixed ~headers:[ ("content-type", "text/plain") ] response)
  |> Eta.Effect.bind_error (fun _error -> Eta.Effect.pure (empty 500))

let empty_after_body request =
  Eta_http.Server.Body.read_all request.Eta_http.Server.Request.body
  |> Eta.Effect.map (fun _body -> empty 200)

let trailer_response () =
  Eta.Effect.pure
    (Eta_http.Server.Response.make ~status:200
       ~headers:(header_list [ ("trailer", "x-trailer") ])
       ~trailers:(fun () ->
         Eta.Effect.pure (header_list [ ("x-trailer", "eta-trailer") ]))
       ~body:
         (Eta_http.Server.Response.Body.string "body-with-trailer")
       ())

let handler ~temp_dir request =
  match request.Eta_http.Server.Request.path with
  | "/" -> Eta.Effect.pure (empty 200)
  | "/user" when String.equal request.Eta_http.Server.Request.method_ "POST" ->
      empty_after_body request
  | "/healthz" -> Eta.Effect.pure (text "ok\n")
  | "/echo" | "/reflect" -> echo_response request
  | "/echo_once" -> echo_once_response request
  | "/trailer" -> trailer_response ()
  | path -> (
      match user_id_response path with
      | Some response -> Eta.Effect.pure response
      | None -> (
          match static_response ~temp_dir path with
          | Some response -> Eta.Effect.pure response
          | None -> (
              match redirect_response path with
              | Some response -> Eta.Effect.pure response
              | None -> (
                  match status_response path with
                  | Some response -> Eta.Effect.pure response
                  | None -> Eta.Effect.pure (empty 404)))))

let config =
  let body_limit = 128 * 1024 * 1024 in
  let server =
    {
      Eta_http.Server.Config.default with
      unread_body_policy = Drain_up_to body_limit;
      limits =
        {
          Eta_http.Server.Config.default.limits with
          max_request_body_bytes = Some body_limit;
        };
    }
  in
  {
    Eta_http_eio.Server.Config.default with
    server;
    h2_config =
      {
        Eta_http_eio.Server.Config.default.h2_config with
        max_concurrent_streams = 4096;
      };
  }

let tls_config cert_dir protocol =
  let alpn_protocols =
    match protocol with H1 -> [ "http/1.1" ] | H2 -> [ "h2"; "http/1.1" ]
  in
  Eta_http.Tls.Config.default_server
    ~certificate_chain_file:(Certs.cert_path cert_dir)
    ~private_key_file:(Certs.key_path cert_dir) ~alpn_protocols ()

let start ~sw ~env ~port ~temp_dir ?cert_dir ~protocol ~transport () =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let handler = handler ~temp_dir in
  match (protocol, transport) with
  | H1, Plain ->
      Ok
        (Eta_http_eio.Server.start_h1 ~sw ~net ~clock ~config ~addr handler)
  | H2, Plain ->
      Ok
        (Eta_http_eio.Server.start_h2c ~sw ~net ~clock ~config ~addr handler)
  | (H1 | H2), TLS -> (
      match cert_dir with
      | None -> Error "eta TLS server requires cert_dir"
      | Some cert_dir ->
          let tls_config = tls_config cert_dir protocol in
          (* ETA_SERVER_DOMAINS=n runs the HTTPS listener across n Eio accept/
             handshake domains so CPU-bound TLS handshakes parallelize across
             cores (see http-testsuite/README.md). Unset/<=0 keeps a single
             domain. Capped by io_uring memlock; do not use Recommended here. *)
          let domain_policy =
            match Sys.getenv_opt "ETA_SERVER_DOMAINS" with
            | Some s -> (
                match int_of_string_opt (String.trim s) with
                | Some n when n > 0 -> Eta_http_eio.Server.Additional n
                | _ -> Eta_http_eio.Server.Single_domain)
            | None -> Eta_http_eio.Server.Single_domain
          in
          Ok
            (Eta_http_eio.Server.start_https ~sw ~net ~clock ~config
               ~domain_manager:(Eio.Stdenv.domain_mgr env) ~domain_policy
               ~tls_config ~addr handler))

let stop t =
  Eta_http_eio.Server.shutdown t Immediate;
  Ok ()
