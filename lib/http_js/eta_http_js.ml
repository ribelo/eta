(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Js = Js_of_ocaml.Js
module Unsafe = Js_of_ocaml.Js.Unsafe
module Typed_array = Js_of_ocaml.Typed_array

module Body = Eta_http.Body
module Http_client = Eta_http.Client
module Error = Eta_http.Error
module Header = Eta_http.Core.Header
module Request = Eta_http.Request
module Response = Eta_http.Response
module Url = Eta_http.Core.Url

let adapter = "eta_http_js"
let default_max_buffered_request_body_bytes = Body.Stream.default_max_bytes

exception Host_promise_rejected of string

let js_typeof =
  Unsafe.js_expr "(function(value) { return typeof value; })"

let js_to_string =
  Unsafe.js_expr
    "(function(value) { try { return String(value); } catch (_) { return '<unprintable>'; } })"

let js_is_nullish =
  Unsafe.js_expr "(function(value) { return value === null || value === undefined; })"

let js_type value =
  Js.to_string
    (Unsafe.fun_call js_typeof [| Unsafe.inject value |])

let js_string value =
  Js.to_string
    (Unsafe.fun_call js_to_string [| Unsafe.inject value |])

let is_nullish value =
  Js.to_bool
    (Unsafe.fun_call js_is_nullish [| Unsafe.inject value |])

let is_function value = String.equal (js_type value) "function"

let error ?request kind =
  match request with
  | Some request -> Error.make ~method_:request.Request.method_ ~uri:request.uri kind
  | None -> Error.make ~method_:"*" ~uri:"*" kind

let unsupported ?request ~feature message =
  error ?request
    (Unsupported_adapter_feature { adapter; feature; message })

let host_api_unavailable ?request ~api message =
  error ?request (Host_api_unavailable { api; message })

let host_api_error ?request ~api message =
  error ?request (Host_api_error { api; message })

let host_policy_error ?request ~policy message =
  error ?request (Host_policy_error { policy; message })

let protocol_options_error request options =
  match options.Http_client.selected_protocol with
  | Http_client.Auto -> (
      match options.ca_file with
      | None -> None
      | Some _ ->
          Some
            (unsupported ~request ~feature:"ca_file"
               "Fetch does not expose custom CA trust stores"))
  | Http_client.H1 ->
      Some
        (unsupported ~request ~feature:"protocol"
           "Fetch does not expose forced HTTP/1.1 selection")
  | Http_client.H2 ->
      Some
        (unsupported ~request ~feature:"protocol"
           "Fetch does not expose forced HTTP/2 selection")

let forbidden_header_name name =
  match Header.normalize_name name with
  | "accept-charset" | "accept-encoding" | "access-control-request-headers"
  | "access-control-request-method" | "connection" | "content-length"
  | "cookie" | "cookie2" | "date" | "dnt" | "expect" | "host"
  | "keep-alive" | "origin" | "referer" | "set-cookie" | "te" | "trailer"
  | "transfer-encoding" | "upgrade" | "via" ->
      true
  | name ->
      Eta.String_helpers.starts_with ~prefix:"proxy-" name
      || Eta.String_helpers.starts_with ~prefix:"sec-" name

let valid_method_token method_ =
  let len = String.length method_ in
  let rec loop index =
    index = len
    ||
    match String.unsafe_get method_ index with
    | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_'
    | '`' | '|' | '~'
    | '0' .. '9' | 'A' .. 'Z' | 'a' .. 'z' ->
        loop (index + 1)
    | _ -> false
  in
  len > 0 && loop 0

let method_has_body_forbidden method_ =
  String.equal method_ "get" || String.equal method_ "head"

let request_has_body request =
  match request.Request.body with Empty -> false | Fixed _ | Stream _ | Rewindable_stream _ -> true

let validate_method request =
  if not (valid_method_token request.Request.method_) then
    Some
      (error ~request
         (Connection_protocol_violation
            { kind = "method"; message = "invalid HTTP method token" }))
  else
    match Eta.String_helpers.lowercase_ascii request.Request.method_ with
    | "connect" | "trace" | "track" ->
        Some
          (host_policy_error ~request ~policy:"fetch-forbidden-method"
             "Fetch forbids CONNECT, TRACE, and TRACK request methods")
    | method_ when method_has_body_forbidden method_ && request_has_body request ->
        Some
          (error ~request
             (Connection_protocol_violation
                {
                  kind = "request_body";
                  message = "GET and HEAD requests cannot carry bodies";
                }))
    | _ -> None

let validate_url request =
  match Url.parse request.Request.uri with
  | Ok _ -> None
  | Error parse_error ->
      Some
        (error ~request
           (Connection_protocol_violation
              {
                kind = "url";
                message = Url.parse_error_to_string parse_error;
              }))

let validate_headers request =
  match Header.validate request.Request.headers with
  | Some kind -> Some (error ~request kind)
  | None ->
      let seen = Hashtbl.create 16 in
      let rec loop = function
        | [] -> None
        | (name, _) :: rest ->
            let normalized = Header.normalize_name name in
            if forbidden_header_name name then
              Some
                (host_policy_error ~request ~policy:"fetch-forbidden-header"
                   ("Fetch forbids request header " ^ normalized))
            else if Hashtbl.mem seen normalized then
              Some
                (host_policy_error ~request ~policy:"duplicate-request-header"
                   ("duplicate request header " ^ normalized))
            else (
              Hashtbl.add seen normalized ();
              loop rest)
      in
      loop request.Request.headers

let validate_request options request =
  match protocol_options_error request options with
  | Some error -> Error error
  | None -> (
      match validate_method request with
      | Some error -> Error error
      | None -> (
          match validate_url request with
          | Some error -> Error error
          | None -> (
              match validate_headers request with
              | Some error -> Error error
              | None -> Ok ())))

let require_global_function request api =
  let value = Unsafe.get Unsafe.global api in
  if is_function value then Ok value
  else
    Error
      (host_api_unavailable ?request ~api
         ("globalThis." ^ api ^ " is not available"))

let await_host_promise ?on_cancel ?request ~api promise =
  Eta.Effect.sync (fun () ->
      let eta_promise, resolver = Eta_jsoo.Private.create_promise () in
      let setup =
        try
          let on_fulfilled =
            Js.wrap_callback (fun value ->
                Eta_jsoo.Private.resolve resolver value)
          in
          let on_rejected =
            Js.wrap_callback (fun reason ->
                Eta_jsoo.Private.reject resolver
                  (Host_promise_rejected (js_string reason)))
          in
          ignore
            (Unsafe.meth_call promise "then"
               [|
                 Unsafe.inject on_fulfilled;
                 Unsafe.inject on_rejected;
               |]);
          Ok ()
        with exn -> Error (host_api_error ?request ~api (Printexc.to_string exn))
      in
      match setup with
      | Error _ as error -> error
      | Ok () -> (
          try
            let value =
              match on_cancel with
              | None -> Eta_jsoo.Private.await eta_promise
              | Some on_cancel -> Eta_jsoo.Private.await ~on_cancel eta_promise
            in
            Ok value
          with Host_promise_rejected message ->
            Error (host_api_error ?request ~api message)))
  |> Eta.Effect.flatten_result

let call_host_promise ?on_cancel ?request ~api f =
  Eta.Effect.sync (fun () ->
      try Ok (f ())
      with exn -> Error (host_api_error ?request ~api (Printexc.to_string exn)))
  |> Eta.Effect.flatten_result
  |> Eta.Effect.bind (await_host_promise ?on_cancel ?request ~api)

let map_request_body_error request error =
  match error.Error.kind with
  | Body_too_large { limit; length } ->
      Error.make ~method_:request.Request.method_ ~uri:request.uri
        (Request_body_too_large { limit; length })
  | _ -> error

let collect_rewindable request ~max_buffered_request_body_bytes ~declared_length make =
  match declared_length with
  | Some length when length > max_buffered_request_body_bytes ->
      Eta.Effect.fail
        (error ~request
           (Request_body_too_large
              { limit = max_buffered_request_body_bytes; length }))
  | _ ->
      Body.Stream.read_all ~max_bytes:max_buffered_request_body_bytes (make ())
      |> Eta.Effect.map_error (map_request_body_error request)

let collect_request_body request ~max_buffered_request_body_bytes =
  match request.Request.body with
  | Empty -> Eta.Effect.pure None
  | Fixed chunks -> Eta.Effect.pure (Some (Bytes.concat Bytes.empty chunks))
  | Stream _ ->
      Eta.Effect.fail
        (unsupported ~request ~feature:"request_body_stream"
           "Fetch upload streaming is not supported by eta_http_js")
  | Rewindable_stream { length; make } ->
      collect_rewindable request ~max_buffered_request_body_bytes
        ~declared_length:length make
      |> Eta.Effect.map Option.some

let make_headers request headers_ctor =
  Eta.Effect.sync (fun () ->
      try
        let headers = Unsafe.new_obj headers_ctor [||] in
        List.iter
          (fun (name, value) ->
            ignore
              (Unsafe.meth_call headers "append"
                 [|
                   Unsafe.inject (Js.string name);
                   Unsafe.inject (Js.string value);
                 |]))
          request.Request.headers;
        Ok headers
      with exn ->
        Error
          (host_api_error ~request ~api:"Headers"
             (Printexc.to_string exn)))
  |> Eta.Effect.flatten_result

let make_request_init request headers body controller =
  let signal = Unsafe.get controller "signal" in
  let init =
    Unsafe.obj
      [|
        ("method", Unsafe.inject (Js.string request.Request.method_));
        ("headers", Unsafe.inject headers);
        ("signal", Unsafe.inject signal);
        ("mode", Unsafe.inject (Js.string "cors"));
        ("redirect", Unsafe.inject (Js.string "manual"));
        ("credentials", Unsafe.inject (Js.string "omit"));
        ("referrerPolicy", Unsafe.inject (Js.string "no-referrer"));
        ("cache", Unsafe.inject (Js.string "no-store"));
      |]
  in
  Option.iter
    (fun bytes ->
      Unsafe.set init "body"
        (Typed_array.Bytes.to_uint8Array bytes))
    body;
  init

let start_fetch request body =
  Eta.Effect.sync (fun () ->
      match require_global_function (Some request) "fetch" with
      | Error _ as error -> error
      | Ok fetch -> (
          match require_global_function (Some request) "AbortController" with
          | Error _ as error -> error
          | Ok abort_controller -> (
              match require_global_function (Some request) "Headers" with
              | Error _ as error -> error
              | Ok headers_ctor ->
                  try
                    let controller = Unsafe.new_obj abort_controller [||] in
                    Ok (fetch, headers_ctor, controller)
                  with exn ->
                    Error
                      (host_api_error ~request ~api:"AbortController"
                         (Printexc.to_string exn)))))
  |> Eta.Effect.flatten_result
  |> Eta.Effect.bind (fun (fetch, headers_ctor, controller) ->
         make_headers request headers_ctor
         |> Eta.Effect.bind (fun headers ->
                let init = make_request_init request headers body controller in
                let on_cancel () =
                  ignore (Unsafe.meth_call controller "abort" [||])
                in
                call_host_promise ~on_cancel ~request ~api:"fetch" (fun () ->
                    Unsafe.fun_call fetch
                      [|
                        Unsafe.inject (Js.string request.Request.uri);
                        Unsafe.inject init;
                      |])))

let response_type response =
  let value = Unsafe.get response "type" in
  if is_nullish value then "" else js_string value

let response_status response = Unsafe.get response "status"

let visible_response request response =
  match response_type response with
  | "opaque" | "opaqueredirect" ->
      Error
        (host_policy_error ~request ~policy:"opaque-fetch-response"
           "Fetch returned an opaque response without HTTP status or headers")
  | _ ->
      let status = response_status response in
      if status = 0 then
        Error
          (host_policy_error ~request ~policy:"opaque-fetch-response"
             "Fetch returned status 0, which is not an HTTP response status")
      else Ok status

let response_headers request response =
  Eta.Effect.sync (fun () ->
      try
        let headers = Unsafe.get response "headers" in
        let for_each = Unsafe.get headers "forEach" in
        if not (is_function for_each) then
          Error
            (host_api_error ~request ~api:"Headers.forEach"
               "Fetch response headers are not iterable")
        else
          let collected = ref [] in
          let callback =
            Js.wrap_callback (fun value name ->
                collected := (js_string name, js_string value) :: !collected)
          in
          ignore
            (Unsafe.meth_call headers "forEach"
               [| Unsafe.inject callback |]);
          Ok (List.rev !collected)
      with exn ->
        Error
          (host_api_error ~request ~api:"Headers.forEach"
             (Printexc.to_string exn)))
  |> Eta.Effect.flatten_result

let release_lock ?request reader =
  Eta.Effect.sync (fun () ->
      let release_lock = Unsafe.get reader "releaseLock" in
      if is_function release_lock then
        try Ok (ignore (Unsafe.meth_call reader "releaseLock" [||]))
        with exn ->
          Error
            (host_api_error ?request ~api:"ReadableStreamDefaultReader.releaseLock"
               (Printexc.to_string exn))
      else Ok ())
  |> Eta.Effect.flatten_result

let cancel_reader ?request reader =
  Eta.Effect.sync (fun () ->
      let cancel = Unsafe.get reader "cancel" in
      if is_function cancel then Ok (Some cancel) else Ok None)
  |> Eta.Effect.flatten_result
  |> Eta.Effect.bind (function
       | None -> Eta.Effect.unit
       | Some _ ->
           call_host_promise ?request
             ~api:"ReadableStreamDefaultReader.cancel"
             (fun () -> Unsafe.meth_call reader "cancel" [||])
           |> Eta.Effect.map (fun _ -> ()))

let body_too_large request ~limit ~length =
  Error.make ~method_:request.Request.method_ ~uri:request.uri
    (Body_too_large { limit; length })

let stream_response_body request response ~max_response_body_bytes =
  Eta.Effect.sync (fun () ->
      try
        let body = Unsafe.get response "body" in
        if is_nullish body then Ok (`Empty)
        else
          let get_reader = Unsafe.get body "getReader" in
          if is_function get_reader then
            Ok (`Reader (Unsafe.meth_call body "getReader" [||]))
          else Ok `Array_buffer
      with exn ->
        Error
          (host_api_error ~request ~api:"Response.body"
             (Printexc.to_string exn)))
  |> Eta.Effect.flatten_result
  |> Eta.Effect.bind (function
       | `Empty -> Eta.Effect.pure (Body.Stream.empty ())
       | `Array_buffer ->
           call_host_promise ~request ~api:"Response.arrayBuffer" (fun () ->
               Unsafe.meth_call response "arrayBuffer" [||])
           |> Eta.Effect.bind (fun array_buffer ->
                  let bytes =
                    Typed_array.Bytes.of_arrayBuffer
                      (Unsafe.coerce array_buffer)
                  in
                  let length = Bytes.length bytes in
                  if length > max_response_body_bytes then
                    Eta.Effect.fail
                      (body_too_large request
                         ~limit:max_response_body_bytes ~length)
                  else Eta.Effect.pure (Body.Stream.of_bytes [ Bytes.copy bytes ]))
       | `Reader reader ->
           let total = ref 0 in
           let finished = ref false in
           let read_next () =
             call_host_promise ~request
               ~api:"ReadableStreamDefaultReader.read"
               (fun () -> Unsafe.meth_call reader "read" [||])
             |> Eta.Effect.bind (fun chunk ->
                    let done_ : bool Js.t = Unsafe.get chunk "done" in
                    if Js.to_bool done_ then (
                      finished := true;
                      Eta.Effect.pure Body.Stream.End)
                    else
                      let value = Unsafe.get chunk "value" in
                      let bytes =
                        Typed_array.Bytes.of_uint8Array
                          (Unsafe.coerce value)
                      in
                      let length = !total + Bytes.length bytes in
                      if length < !total || length > max_response_body_bytes
                      then
                        let error =
                          body_too_large request
                            ~limit:max_response_body_bytes ~length
                        in
                        finished := true;
                        cancel_reader ~request reader
                        |> Eta.Effect.ignore_errors
                        |> Eta.Effect.bind (fun () -> Eta.Effect.fail error)
                      else (
                        total := length;
                        Eta.Effect.pure
                          (Body.Stream.Chunk (Bytes.copy bytes))))
           in
           let release () =
             if !finished then release_lock ~request reader
             else (
               finished := true;
               cancel_reader ~request reader)
           in
           Eta.Effect.pure (Body.Stream.of_reader ~release read_next))

let decode_response request options response =
  Eta.Effect.from_result (visible_response request response)
  |> Eta.Effect.bind (fun status ->
         response_headers request response
         |> Eta.Effect.bind (fun headers ->
                stream_response_body request response
                  ~max_response_body_bytes:options.Http_client.max_response_body_bytes
                |> Eta.Effect.map (fun body ->
                       Response.make ~status ~headers ~body
                         ~trailers:(fun () -> Eta.Effect.pure Header.empty)
                         ())))

let request_with_options ~max_buffered_request_body_bytes options request =
  Eta.Effect.from_result (validate_request options request)
  |> Eta.Effect.bind (fun () ->
         collect_request_body request ~max_buffered_request_body_bytes)
  |> Eta.Effect.bind (fun body -> start_fetch request body)
  |> Eta.Effect.bind (decode_response request options)

let validate_non_negative name value =
  if value < 0 then invalid_arg (name ^ " must be >= 0")

let runtime_service ?(max_buffered_request_body_bytes =
                        default_max_buffered_request_body_bytes) () =
  validate_non_negative
    "Eta_http_js.runtime_service: max_buffered_request_body_bytes"
    max_buffered_request_body_bytes;
  Http_client.runtime_service
    {
      request =
        (fun options request ->
          request_with_options ~max_buffered_request_body_bytes options request);
      stats = (fun _ -> Eta.Effect.pure None);
      shutdown = (fun _ -> Eta.Effect.unit);
    }

module Client = struct
  let make
      ?(max_response_body_bytes = Eta_http.Client.default_max_response_body_bytes)
      ?(max_buffered_request_body_bytes =
        default_max_buffered_request_body_bytes) () =
    validate_non_negative
      "Eta_http_js.Client.make: max_response_body_bytes"
      max_response_body_bytes;
    validate_non_negative
      "Eta_http_js.Client.make: max_buffered_request_body_bytes"
      max_buffered_request_body_bytes;
    let options =
      {
        Eta_http.Client.selected_protocol = Eta_http.Client.Auto;
        max_response_body_bytes;
        ca_file = None;
      }
    in
    Eta_http.Client.make_custom ~protocol:Eta_http.Client.Auto
      ~request:(request_with_options ~max_buffered_request_body_bytes options)
      ~stats:(fun () -> Eta.Effect.pure None)
      ~shutdown:(fun () -> Eta.Effect.unit)
end
