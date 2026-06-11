(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Server = Eta_http.Server
module Types = Server_types

type flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

type stats = Server_stats.H1.snapshot = {
  active_requests : int;
  completed_requests : int;
  request_bytes : int;
  response_bytes : int;
  protocol_errors : int;
}

type t = {
  sw : Eio.Switch.t;
  with_timeout : 'a. Eta.Duration.t -> (unit -> 'a) -> 'a;
  flow : flow;
  connection : Types.Connection_info.t;
  config : Types.Config.t;
  runtime_factory : Types.runtime_factory;
  stats : Server_stats.H1.t;
  connection_metrics : Server_metrics.t option;
  mutable current_metrics : Server_metrics.t option;
  mutable pending : bytes;
  mutable pending_off : int;
  mutable pending_len : int;
  mutable closed : bool;
}

type target_authority = {
  value : string;
  scheme : Eta_http.Core.Url.scheme;
  host : string;
  port : int;
}

type request_head = {
  method_ : string;
  target : string;
  target_authority : target_authority option;
  version : Eta_http.Core.Version.t;
  headers : Eta_http.Core.Header.t;
  body_initial : bytes;
}

type continue_state = { mutable sent : bool }

type body_source = {
  t : t;
  initial : bytes;
  mutable off : int;
  mutable remaining : int;
  mutable close_after_response : bool;
  mutable pending_returned : bool;
  continue_state : continue_state option;
  scratch : Cstruct.t;
}

type chunked_body_source = {
  source : body_source;
  decoder : Eta_http.Body.Chunked.t;
  mutable done_ : bool;
}

type request_body_control =
  | No_request_body
  | Fixed_request_body of body_source
  | Chunked_request_body of chunked_body_source
  | Close_after_response

type request_head_error =
  | Clean_eof
  | Request_head_error of Server.Error.t

let stats t : stats = Server_stats.H1.snapshot t.stats

let validate_config config =
  if config.Types.Config.read_buffer_size <= 0 then
    invalid_arg
      "Eta_http_eio.H1.Server_connection.run: read_buffer_size must be > 0";
  Eta_http.Server.Config.validate config.server

let error t ?(method_ = "*") ?(target = "*") kind =
  Server.Error.make ~protocol:t.connection.protocol ~method_ ~target kind

let connection_closed_error t during =
  error t (Connection_closed { during })

let request_timeout_error t timeout =
  error t
    (Request_timeout
       { timeout_ms = Option.map Eta.Duration.to_ms timeout })

let request_parse_error t parse_error =
  let message =
    Eta_http.H1.Request_parse.parse_error_to_string parse_error
  in
  error t (Bad_request { message })

let response_write_error t message =
  error t (Response_write_failed { message })

let write_response_string t wire =
  try
    let write () = Eio.Flow.copy_string wire t.flow in
    (match t.config.server.timeouts.response_write_timeout with
    | None -> write ()
    | Some timeout -> t.with_timeout timeout write);
    Server_stats.H1.add_response_bytes t.stats (String.length wire);
    Ok ()
  with
  | Eio.Time.Timeout ->
      Error (response_write_error t "response write timed out")
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Error
        (response_write_error t
           ("connection write failed: " ^ Printexc.to_string exn))

let emit_current t f =
  Option.iter f t.current_metrics

let emit_connection t f =
  match t.current_metrics with
  | Some metrics -> f metrics
  | None -> Option.iter f t.connection_metrics

let record_protocol_error t =
  Server_stats.H1.protocol_error t.stats;
  emit_connection t (fun metrics -> Server_metrics.protocol_errors metrics 1)

let find_failure cause =
  let rec loop = function
    | Eta.Cause.Fail error -> Some error
    | Die _ | Interrupt _ | Finalizer _ -> None
    | Sequential causes | Concurrent causes -> List.find_map loop causes
    | Suppressed { primary; _ } -> loop primary
  in
  loop cause

let fallback_error_response t request cause =
  let message = Format.asprintf "%a" (Eta.Cause.pp Server.Error.pp) cause in
  let error =
    match find_failure cause with
    | Some error -> error
    | None ->
        Server.Error.make ~protocol:t.connection.protocol
          ~method_:request.Server.Request.method_ ~target:request.target
          (Handler_failed { message })
  in
  Server.Handler.default_error_response error

let min_positive left right =
  if left <= 0 then right else if right <= 0 then left else min left right

let push_pending t bytes off len =
  if len <= 0 then ()
  else
    let fresh = Bytes.sub bytes off len in
    if t.pending_len = 0 then (
      t.pending <- fresh;
      t.pending_off <- 0;
      t.pending_len <- len)
    else
      let combined = Bytes.create (len + t.pending_len) in
      Bytes.blit fresh 0 combined 0 len;
      Bytes.blit t.pending t.pending_off combined len t.pending_len;
      t.pending <- combined;
      t.pending_off <- 0;
      t.pending_len <- Bytes.length combined

let read_pending t dst dst_off len =
  let read = min len t.pending_len in
  if read > 0 then (
    Bytes.blit t.pending t.pending_off dst dst_off read;
    t.pending_off <- t.pending_off + read;
    t.pending_len <- t.pending_len - read;
    if t.pending_len = 0 then (
      t.pending <- Bytes.empty;
      t.pending_off <- 0));
  read

let read_flow_into_bytes t dst dst_off len =
  let pending = read_pending t dst dst_off len in
  if pending > 0 then pending
  else
    let scratch = Cstruct.create len in
    let read =
      try Eio.Flow.single_read t.flow scratch with
      | End_of_file -> 0
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          raise
            (Failure
               ("Eta_http_eio.H1.Server_connection.read: "
              ^ Printexc.to_string exn))
    in
    if read > 0 then Cstruct.blit_to_bytes scratch 0 dst dst_off read;
    read

let request_head_capacity config =
  let limits = config.Types.Config.server.Eta_http.Server.Config.limits in
  limits.max_request_line_bytes + limits.max_request_header_bytes + 4

let read_request_head t =
  let limits = t.config.server.limits in
  let capacity = request_head_capacity t.config in
  let buffer = Bytes.create capacity in
  let scratch_len = min_positive t.config.read_buffer_size capacity in
  let rec loop used =
    match
      Eta_http.H1.Request_parse.parse buffer ~len:used
        ~max_request_line_bytes:limits.max_request_line_bytes
        ~max_header_bytes:limits.max_request_header_bytes
        ~max_headers:limits.max_request_headers
    with
    | Ok request ->
        let body_len = used - request.body_off in
        let body_initial = Bytes.create body_len in
        if body_len > 0 then
          Bytes.blit buffer request.body_off body_initial 0 body_len;
        let headers =
          Eta_http.Core.Header.unsafe_of_list
            (Eta_http.H1.Request_parse.headers_to_list buffer request.headers)
        in
        Ok
          {
            method_ = Eta_http.H1.Request_parse.method_to_string buffer request;
            target = Eta_http.H1.Request_parse.target_to_string buffer request;
            target_authority = None;
            version = request.version;
            headers;
            body_initial;
          }
    | Error Eta_http.H1.Request_parse.Partial ->
        if used >= capacity then
          Error
            (Request_head_error
               (request_parse_error t
                  (Header_section_too_large
                     { limit = limits.max_request_header_bytes })))
        else
          let read_len = min scratch_len (capacity - used) in
          let read = read_flow_into_bytes t buffer used read_len in
          if read = 0 then
            if used = 0 then Error Clean_eof
            else
              Error
                (Request_head_error
                   (connection_closed_error t Request_headers))
          else loop (used + read)
    | Error parse_error ->
        Error (Request_head_error (request_parse_error t parse_error))
  in
  loop 0

let source_pending source =
  Bytes.length source.initial - source.off

let send_continue_if_needed source =
  match source.continue_state with
  | None -> Eta.Effect.unit
  | Some state when state.sent -> Eta.Effect.unit
  | Some state ->
      state.sent <- true;
      (match write_response_string source.t "HTTP/1.1 100 Continue\r\n\r\n" with
      | Ok () -> Eta.Effect.unit
      | Error error -> Eta.Effect.fail error)

let finish_body_source source =
  if not source.pending_returned then (
    source.pending_returned <- true;
    if (not source.close_after_response) && source.remaining = 0 then
      push_pending source.t source.initial source.off (source_pending source);
    source.off <- Bytes.length source.initial)

let source_take_pending source n =
  let take = min n (source_pending source) in
  let chunk = Bytes.sub source.initial source.off take in
  source.off <- source.off + take;
  chunk

let read_body_flow source dst =
  try
    let read =
      match source.t.config.server.timeouts.request_body_timeout with
      | None -> Eio.Flow.single_read source.t.flow dst
      | Some timeout ->
          source.t.with_timeout timeout (fun () ->
              Eio.Flow.single_read source.t.flow dst)
    in
    Ok read
  with
  | End_of_file -> Ok 0
  | Eio.Time.Timeout ->
      Error
        (request_timeout_error source.t
           source.t.config.server.timeouts.request_body_timeout)
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | _ -> Error (connection_closed_error source.t Request_body)

let source_read_some source max_len =
  if max_len <= 0 || source.remaining <= 0 then (
    finish_body_source source;
    Eta.Effect.pure None)
  else
    send_continue_if_needed source
    |> Eta.Effect.bind (fun () ->
           if source_pending source > 0 then
             let chunk =
               source_take_pending source (min max_len source.remaining)
             in
             source.remaining <- source.remaining - Bytes.length chunk;
             if source.remaining = 0 then finish_body_source source;
             Server_stats.H1.add_request_bytes source.t.stats
               (Bytes.length chunk);
             emit_current source.t (fun metrics ->
                 Server_metrics.request_body_bytes metrics (Bytes.length chunk));
             Eta.Effect.pure (Some chunk)
           else
             let len =
               min max_len (min source.remaining (Cstruct.length source.scratch))
             in
             Eta.Effect.sync (fun () ->
                 read_body_flow source (Cstruct.sub source.scratch 0 len))
             |> Eta.Effect.bind (function
                  | Error error -> Eta.Effect.fail error
                  | Ok 0 ->
                      Eta.Effect.fail
                        (connection_closed_error source.t Request_body)
                  | Ok read ->
                      let chunk = Bytes.create read in
                      Cstruct.blit_to_bytes source.scratch 0 chunk 0 read;
                      source.remaining <- source.remaining - read;
                      if source.remaining = 0 then finish_body_source source;
                      Server_stats.H1.add_request_bytes source.t.stats read;
                      emit_current source.t (fun metrics ->
                          Server_metrics.request_body_bytes metrics read);
                      Eta.Effect.pure (Some chunk)))

let rec drain_fixed_body source =
  source_read_some source source.remaining
  |> Eta.Effect.bind (function
       | None -> Eta.Effect.unit
       | Some _ -> drain_fixed_body source)

let fixed_body t initial length continue_state =
  let source =
    {
      t;
      initial;
      off = 0;
      remaining = length;
      close_after_response = false;
      pending_returned = false;
      continue_state;
      scratch = Cstruct.create t.config.read_buffer_size;
    }
  in
  let body =
    Server.Body.of_reader
      ~discard:(fun ~drain ->
        if drain then drain_fixed_body source
        else (
          source.close_after_response <- true;
          source.remaining <- 0;
          source.pending_returned <- true;
          source.off <- Bytes.length source.initial;
          Eta.Effect.unit))
      (fun () -> source_read_some source source.remaining)
  in
  (body, source)

let chunked_http_error_to_server t (http_error : Eta_http.Error.t) =
  match http_error.kind with
  | Body_too_large { limit; length } ->
      error t (Request_body_too_large { limit; length })
  | Decode_error { codec; message } ->
      error t (Bad_request { message = codec ^ ": " ^ message })
  | Header_invalid { reason } -> error t (Header_invalid { reason })
  | Total_request_timeout { timeout_ms } ->
      error t (Request_timeout { timeout_ms })
  | Connection_closed _ -> connection_closed_error t Request_body
  | kind ->
      error t
        (Protocol_error
           {
             kind = Eta_http.Error.kind_name kind;
             message = Eta_http.Error.to_string http_error;
           })

let chunked_transport_error source kind =
  Eta_http.Error.make ~protocol:H1 ~method_:"*" ~uri:"*" kind

let chunked_read_exact source len =
  send_continue_if_needed source
  |> Eta.Effect.map_error Server.Error.to_http_error
  |> Eta.Effect.bind (fun () ->
         let out = Bytes.create len in
         let rec fill off =
           if off = len then Eta.Effect.pure out
           else if source_pending source > 0 then (
             let chunk = source_take_pending source (len - off) in
             let chunk_len = Bytes.length chunk in
             Bytes.blit chunk 0 out off chunk_len;
             fill (off + chunk_len))
           else
             let read_len = min (len - off) (Cstruct.length source.scratch) in
             Eta.Effect.sync (fun () ->
                 read_body_flow source (Cstruct.sub source.scratch 0 read_len))
             |> Eta.Effect.bind (function
                  | Error error ->
                      Eta.Effect.fail (Server.Error.to_http_error error)
                  | Ok 0 ->
                      Eta.Effect.fail
                        (chunked_transport_error source
                           (Connection_closed { during = Body_decode }))
                  | Ok read ->
                      Cstruct.blit_to_bytes source.scratch 0 out off read;
                      fill (off + read))
         in
         fill 0)

let chunked_decode_error source message =
  Eta_http.Error.make ~protocol:H1 ~method_:"*" ~uri:"*"
    (Decode_error { codec = "chunked"; message })

let chunked_read_line source ~limit =
  let buffer = Buffer.create 32 in
  let rec loop length seen_cr =
    chunked_read_exact source 1
    |> Eta.Effect.bind (fun byte ->
           let c = Bytes.get byte 0 in
           if seen_cr then
             if Char.equal c '\n' then Eta.Effect.pure (Buffer.contents buffer)
             else if length + 2 > limit then
               Eta.Effect.fail
                 (chunked_decode_error source "chunk line too large")
             else (
               Buffer.add_char buffer '\r';
               Buffer.add_char buffer c;
               loop (length + 2) false)
           else if Char.equal c '\r' then loop length true
           else if length + 1 > limit then
             Eta.Effect.fail
               (chunked_decode_error source "chunk line too large")
           else (
             Buffer.add_char buffer c;
             loop (length + 1) false))
  in
  loop 0 false

let chunked_body t head continue_state =
  let source =
    {
      t;
      initial = head.body_initial;
      off = 0;
      remaining = max_int;
      close_after_response = false;
      pending_returned = false;
      continue_state;
      scratch = Cstruct.create t.config.read_buffer_size;
    }
  in
  let max_decoded_bytes =
    Option.value t.config.server.limits.max_request_body_bytes ~default:max_int
  in
  let context =
    {
      Eta_http.Body.Chunked.protocol = H1;
      method_ = head.method_;
      uri = head.target;
    }
  in
  let reader =
    {
      Eta_http.Body.Chunked.read_exact = chunked_read_exact source;
      read_line = chunked_read_line source;
    }
  in
  let decoder =
    Eta_http.Body.Chunked.create ~max_decoded_bytes
      ~max_trailer_bytes:t.config.server.limits.max_trailer_bytes
      ~max_trailers:t.config.server.limits.max_trailers ~context ~reader ()
  in
  let state = { source; decoder; done_ = false } in
  let rec read () =
    Eta_http.Body.Chunked.read decoder
    |> Eta.Effect.map_error (chunked_http_error_to_server t)
    |> Eta.Effect.map (function
         | None ->
             state.done_ <- true;
             None
         | Some chunk ->
             Server_stats.H1.add_request_bytes t.stats (Bytes.length chunk);
             emit_current t (fun metrics ->
                 Server_metrics.request_body_bytes metrics (Bytes.length chunk));
             Some chunk)
  in
  let rec drain () =
    read ()
    |> Eta.Effect.bind (function
         | None -> Eta.Effect.unit
         | Some _ -> drain ())
  in
  let body =
    Server.Body.of_reader
      ~discard:(fun ~drain:should_drain ->
        if should_drain then drain ()
        else (
          source.close_after_response <- true;
          state.done_ <- true;
          Eta.Effect.unit))
      read
  in
  (body, state)

let request_body t head continue_state =
  match Eta_http.H1.Request_body.of_headers head.headers with
  | Error body_error ->
      Error
        (error t
           (Header_invalid
              { reason = Eta_http.H1.Request_body.error_to_string body_error }))
  | Ok No_body ->
      push_pending t head.body_initial 0 (Bytes.length head.body_initial);
      Ok
        ( Server.Body.empty (),
          (fun () -> Eta.Effect.pure Eta_http.Core.Header.empty),
          No_request_body )
  | Ok (Fixed length) ->
      let limit = t.config.server.limits.max_request_body_bytes in
      (match limit with
      | Some limit when length > limit ->
          Error (error t (Request_body_too_large { limit; length }))
      | None | Some _ ->
          let body, source = fixed_body t head.body_initial length continue_state in
          Ok
            ( body,
              (fun () -> Eta.Effect.pure Eta_http.Core.Header.empty),
              Fixed_request_body source ))
  | Ok Chunked ->
      let body, source = chunked_body t head continue_state in
      Ok
        ( body,
          (fun () ->
            Eta.Effect.pure
              (if source.done_ then Eta_http.Body.Chunked.trailers source.decoder
               else Eta_http.Core.Header.empty)),
          Chunked_request_body source )

let request_of_head t head ordinal body trailers =
  let path, query = Server.Request.split_target head.target in
  let authority =
    match head.target_authority with
    | Some authority -> Some authority.value
    | None -> Eta_http.Core.Header.get "host" head.headers
  in
  {
    Server.Request.id = t.connection.id ^ "/request-" ^ string_of_int ordinal;
    version = head.version;
    scheme = if t.connection.tls then "https" else "http";
    authority;
    method_ = head.method_;
    target = head.target;
    path;
    query;
    headers = head.headers;
    body;
    trailers;
    peer = t.connection.peer;
    tls = t.connection.tls;
    alpn_protocol = t.connection.alpn_protocol;
    stream_id = None;
    connection_id = t.connection.id;
  }

let header_contains_token headers name token =
  Eta_http.Core.Header.get_all name headers
  |> List.exists (fun value ->
         Eta.String_helpers.contains_token_ascii_ci value token)

let expectation_tokens headers =
  Eta_http.Core.Header.get_all "expect" headers
  |> List.concat_map (String.split_on_char ',')
  |> List.map Eta.String_helpers.trim
  |> List.filter (fun token -> not (String.equal token ""))

let expect_continue t head =
  let values = Eta_http.Core.Header.get_all "expect" head.headers in
  match values with
  | [] -> Ok None
  | _ ->
      let tokens = expectation_tokens head.headers in
      if
        tokens <> []
        && head.version = Eta_http.Core.Version.H1_1
        && List.for_all
             (fun token ->
               Eta.String_helpers.trim_equal_ascii_ci token "100-continue")
             tokens
      then Ok (Some { sent = false })
      else
        let expectation =
          match tokens with
          | [] -> String.concat ", " values
          | _ -> String.concat ", " tokens
        in
        Error
          (error t ~method_:head.method_ ~target:head.target
             (Expectation_failed { expectation }))

let is_hexdig = function
  | '0' .. '9' | 'A' .. 'F' | 'a' .. 'f' -> true
  | _ -> false

let is_reg_name_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' | '!'
  | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ',' | ';' | '=' ->
      true
  | _ -> false

let is_ip_literal_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | ':' | '.' | '-' | '_' | '~'
  | '!' | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ',' | ';' | '=' ->
      true
  | _ -> false

let valid_port value start finish =
  start < finish
  &&
  let rec loop index acc =
    if index = finish then acc >= 1 && acc <= 65535
    else
      match String.unsafe_get value index with
      | '0' .. '9' as c ->
          let next = (acc * 10) + Char.code c - Char.code '0' in
          next <= 65535 && loop (index + 1) next
      | _ -> false
  in
  loop start 0

let valid_reg_name value start finish =
  start < finish
  &&
  let rec loop index =
    if index = finish then true
    else
      match String.unsafe_get value index with
      | '%' ->
          index + 2 < finish
          && is_hexdig (String.unsafe_get value (index + 1))
          && is_hexdig (String.unsafe_get value (index + 2))
          && loop (index + 3)
      | c -> is_reg_name_char c && loop (index + 1)
  in
  loop start

let valid_ip_literal value start finish =
  start < finish
  &&
  let rec loop index =
    if index = finish then true
    else
      is_ip_literal_char (String.unsafe_get value index) && loop (index + 1)
  in
  loop start

let rec find_char_string value index finish char =
  if index >= finish then None
  else if Char.equal (String.unsafe_get value index) char then Some index
  else find_char_string value (index + 1) finish char

let valid_host_authority value =
  let len = String.length value in
  if len = 0 then false
  else if Char.equal (String.unsafe_get value 0) '[' then
    match find_char_string value 1 len ']' with
    | None -> false
    | Some close ->
        valid_ip_literal value 1 close
        &&
        if close + 1 = len then true
        else
          close + 2 < len
          && Char.equal (String.unsafe_get value (close + 1)) ':'
          && valid_port value (close + 2) len
  else
    let host_finish =
      Option.value ~default:len (find_char_string value 0 len ':')
    in
    valid_reg_name value 0 host_finish
    &&
    if host_finish = len then true
    else valid_port value (host_finish + 1) len

let connection_url_scheme t =
  if t.connection.tls then Eta_http.Core.Url.Https else Eta_http.Core.Url.Http

let parse_host_authority ~scheme value =
  if not (valid_host_authority value) then None
  else
    let raw =
      Eta_http.Core.Url.scheme_to_string scheme ^ "://" ^ value
    in
    match Eta_http.Core.Url.parse raw with
    | Error _ -> None
    | Ok url ->
        Some
          ( Eta_http.Core.Url.authority url,
            Eta_http.Core.Url.host url,
            Eta_http.Core.Url.effective_port url )

let validate_authority t head =
  match Eta_http.Core.Header.get_all "host" head.headers with
  | [] when head.version = Eta_http.Core.Version.H1_1 ->
      Error
        (error t ~method_:head.method_ ~target:head.target
           (Bad_request { message = "HTTP/1.1 request is missing Host header" }))
  | [] -> Ok ()
  | [ host ] ->
      let scheme =
        match head.target_authority with
        | Some authority -> authority.scheme
        | None -> connection_url_scheme t
      in
      (match parse_host_authority ~scheme host with
      | None ->
          Error
            (error t ~method_:head.method_ ~target:head.target
               (Bad_request { message = "invalid Host header" }))
      | Some (_, host, port) -> (
          match head.target_authority with
          | Some authority
            when (not (String.equal host authority.host)) || port <> authority.port ->
              Error
                (error t ~method_:head.method_ ~target:head.target
                   (Bad_request
                      {
                        message =
                          "absolute-form request target authority conflicts with \
                           Host header";
                      }))
          | None | Some _ -> Ok ()))
  | _ ->
      Error
        (error t ~method_:head.method_ ~target:head.target
           (Bad_request { message = "multiple Host headers" }))

let target_has_fragment target = Option.is_some (String.index_opt target '#')

let unsupported_request_target t head message =
  Error
    (error t ~method_:head.method_ ~target:head.target
       (Bad_request { message }))

let target_authority_of_url url =
  {
    value = Eta_http.Core.Url.authority url;
    scheme = Eta_http.Core.Url.scheme url;
    host = Eta_http.Core.Url.host url;
    port = Eta_http.Core.Url.effective_port url;
  }

let normalize_request_target t head =
  let target = head.target in
  if String.equal head.method_ "CONNECT" then
    unsupported_request_target t head "CONNECT is not supported by this server"
  else if String.equal target "*" then
    if String.equal head.method_ "OPTIONS" then Ok head
    else
      unsupported_request_target t head
        "asterisk-form request target is only valid with OPTIONS"
  else if String.starts_with ~prefix:"/" target then
    if target_has_fragment target then
      unsupported_request_target t head "request target must not include fragment"
    else Ok head
  else
    match Eta_http.Core.Url.parse target with
    | Error _ ->
        unsupported_request_target t head "invalid request target form"
    | Ok url ->
        if Option.is_some (Eta_http.Core.Url.fragment url) then
          unsupported_request_target t head
            "request target must not include fragment"
        else if Eta_http.Core.Url.scheme url <> connection_url_scheme t then
          unsupported_request_target t head
            "absolute-form request target scheme does not match connection"
        else
          Ok
            {
              head with
              target = Eta_http.Core.Url.origin_form url;
              target_authority = Some (target_authority_of_url url);
            }

let request_allows_keep_alive head =
  let close = header_contains_token head.headers "connection" "close" in
  let keep_alive =
    header_contains_token head.headers "connection" "keep-alive"
  in
  match head.version with
  | Eta_http.Core.Version.H1_1 -> not close
  | Eta_http.Core.Version.H1_0 -> keep_alive && not close
  | Eta_http.Core.Version.H2 -> false

let body_can_reuse_before_response t = function
  | No_request_body -> true
  | Close_after_response -> false
  | Chunked_request_body source ->
      (not source.source.close_after_response) && source.done_
  | Fixed_request_body source ->
      if source.close_after_response then false
      else if
        match source.continue_state with
        | Some state when not state.sent -> true
        | None | Some _ -> false
      then false
      else if source.remaining = 0 then true
      else
        match t.config.server.unread_body_policy with
        | Eta_http.Server.Config.Reset -> false
        | Eta_http.Server.Config.Drain_up_to limit -> source.remaining <= limit

let finish_request_body_for_reuse t rt = function
  | No_request_body -> true
  | Close_after_response -> false
  | Chunked_request_body source ->
      (not source.source.close_after_response) && source.done_
  | Fixed_request_body source ->
      if source.close_after_response then false
      else if source.remaining = 0 then (
        finish_body_source source;
        true)
      else
        match t.config.server.unread_body_policy with
        | Eta_http.Server.Config.Reset -> false
        | Eta_http.Server.Config.Drain_up_to limit ->
            source.remaining <= limit
            &&
            match Eta.Runtime.run rt (drain_fixed_body source) with
            | Eta.Exit.Ok () -> source.remaining = 0
            | Eta.Exit.Error _ -> false

type response_write_failure = {
  error : Server.Error.t;
  response_started : bool;
}

type response_write_success = { connection_close : bool }

let response_write_failure ?(response_started = false) error =
  Error { error; response_started }

let response_error_of_cause t cause =
  match find_failure cause with
  | Some error -> error
  | None ->
      response_write_error t
        (Format.asprintf "%a" (Eta.Cause.pp Server.Error.pp) cause)

let write_response_bytes t bytes =
  match write_response_string t (Bytes.to_string bytes) with
  | Ok () ->
      emit_current t (fun metrics ->
          Server_metrics.response_body_bytes metrics (Bytes.length bytes));
      Ok ()
  | Error error -> response_write_failure ~response_started:true error

let write_response_bytes_list t chunks =
  let rec loop = function
    | [] -> Ok ()
    | chunk :: rest -> (
        match write_response_bytes t chunk with
        | Ok () -> loop rest
        | Error _ as error -> error)
  in
  loop chunks

let release_response_stream rt stream =
  match Eta.Runtime.run rt (stream.Server.Response.Body.release ()) with
  | Eta.Exit.Ok () | Eta.Exit.Error _ -> ()

let with_released_response_stream rt stream f =
  let released = ref false in
  let release_once () =
    if not !released then (
      released := true;
      release_response_stream rt stream)
  in
  Fun.protect ~finally:release_once (fun () ->
      match f () with
      | Ok () ->
          release_once ();
          Ok ()
      | Error _ as error ->
          release_once ();
          error)

let read_response_stream t rt stream =
  match Eta.Runtime.run rt (stream.Server.Response.Body.read ()) with
  | Eta.Exit.Ok chunk -> Ok chunk
  | Eta.Exit.Error cause ->
      response_write_failure ~response_started:true
        (response_error_of_cause t cause)

let response_trailers t rt response =
  match Eta.Runtime.run rt ((Server.Response.trailers response) ()) with
  | Eta.Exit.Ok trailers -> Ok trailers
  | Eta.Exit.Error cause ->
      response_write_failure ~response_started:true
        (response_error_of_cause t cause)

let write_last_chunk t trailers =
  try
    write_response_bytes t
      (Eta_http.H1.Response_write.encode_last_chunk ~trailers ())
  with Invalid_argument message ->
    response_write_failure ~response_started:true
      (response_write_error t message)

let rec pump_fixed_response_stream t rt stream length written =
  match read_response_stream t rt stream with
  | Error _ as error -> error
  | Ok None ->
      if written = length then Ok ()
      else
        response_write_failure ~response_started:true
          (response_write_error t
             "stream ended before declared Content-Length")
  | Ok (Some chunk) ->
      let chunk_length = Bytes.length chunk in
      let next = written + chunk_length in
      if next < written || next > length then
        response_write_failure ~response_started:true
          (response_write_error t
             "stream exceeded declared Content-Length")
      else
        (match write_response_bytes t chunk with
        | Error _ as error -> error
        | Ok () -> pump_fixed_response_stream t rt stream length next)

let rec pump_raw_response_stream t rt stream =
  match read_response_stream t rt stream with
  | Error _ as error -> error
  | Ok None -> Ok ()
  | Ok (Some chunk) -> (
      match write_response_bytes t chunk with
      | Error _ as error -> error
      | Ok () -> pump_raw_response_stream t rt stream)

let rec pump_chunked_response_stream t rt response stream =
  match read_response_stream t rt stream with
  | Error _ as error -> error
  | Ok (Some chunk) -> (
      match
        write_response_bytes_list t
          (Eta_http.H1.Response_write.encode_chunk chunk)
      with
      | Error _ as error -> error
      | Ok () -> pump_chunked_response_stream t rt response stream)
  | Ok None -> (
      match response_trailers t rt response with
      | Error _ as error -> error
      | Ok trailers -> write_last_chunk t trailers)

let write_stream_response t rt response = function
  | Eta_http.H1.Response_write.Stream_fixed stream ->
      with_released_response_stream rt stream (fun () ->
          let length = Option.value stream.length ~default:0 in
          pump_fixed_response_stream t rt stream length 0)
  | Eta_http.H1.Response_write.Stream_chunked stream ->
      with_released_response_stream rt stream (fun () ->
          pump_chunked_response_stream t rt response stream)
  | Eta_http.H1.Response_write.Stream_close_delimited stream ->
      with_released_response_stream rt stream (fun () ->
          pump_raw_response_stream t rt stream)
  | Eta_http.H1.Response_write.No_body | Eta_http.H1.Response_write.Fixed _ ->
      Ok ()

let release_ignored_response_stream rt response =
  match Server.Response.body response with
  | Server.Response.Body.Stream stream -> release_response_stream rt stream
  | Server.Response.Body.Empty | Server.Response.Body.Fixed _ -> ()

let write_response ?(connection_close = false) ?rt t request response =
  match
    Eta_http.H1.Response_write.prepare ~connection_close
      ~version:request.Server.Request.version
      ~request_method:request.method_ response
  with
  | Error error ->
      Option.iter
        (fun rt -> release_ignored_response_stream rt response)
        rt;
      response_write_failure
        (response_write_error t
           (Eta_http.H1.Response_write.error_to_string error))
  | Ok prepared -> (
      match write_response_string t prepared.head with
      | Error error ->
          Option.iter
            (fun rt -> release_ignored_response_stream rt response)
            rt;
          response_write_failure ~response_started:true error
      | Ok () -> (
          match prepared.body with
          | Eta_http.H1.Response_write.No_body ->
              Option.iter
                (fun rt -> release_ignored_response_stream rt response)
                rt;
              Ok { connection_close = prepared.close }
          | Eta_http.H1.Response_write.Fixed chunks ->
              write_response_bytes_list t chunks
              |> Result.map (fun () ->
                     { connection_close = prepared.close })
          | Eta_http.H1.Response_write.Stream_fixed _
          | Eta_http.H1.Response_write.Stream_chunked _
          | Eta_http.H1.Response_write.Stream_close_delimited _ -> (
              match rt with
              | None ->
                  response_write_failure ~response_started:true
                    (response_write_error t
                       "streaming response requires an Eta runtime")
              | Some rt ->
                  write_stream_response t rt response prepared.body
                  |> Result.map (fun () ->
                         { connection_close = prepared.close }))))

let request_metrics t rt request =
  if t.config.server.enable_otel then
    Some
      (Server_metrics.request ~runtime:rt ~connection:t.connection
         ~emit_url_full:t.config.server.emit_url_full request)
  else None

let run_handler t rt request handler =
  let effect =
    Eta_http.Observability.Server.Tracer.request
      ~enabled:t.config.server.enable_otel
      ~emit_url_full:t.config.server.emit_url_full handler request
  in
  match Eta.Runtime.run rt effect with
  | Eta.Exit.Ok response -> response
  | Eta.Exit.Error cause -> fallback_error_response t request cause

let write_default_error ?(connection_close = true) t request error =
  match
    write_response ~connection_close t request
      (Server.Handler.default_error_response error)
  with
  | Ok _ -> ()
  | Error _ -> ()

let request_error_stub t =
  {
    Server.Request.id = t.connection.id ^ "/request-error";
    version = Eta_http.Core.Version.H1_1;
    scheme = if t.connection.tls then "https" else "http";
    authority = None;
    method_ = "*";
    target = "*";
    path = "*";
    query = None;
    headers = Eta_http.Core.Header.empty;
    body = Server.Body.empty ();
    trailers = (fun () -> Eta.Effect.pure Eta_http.Core.Header.empty);
    peer = t.connection.peer;
    tls = t.connection.tls;
    alpn_protocol = t.connection.alpn_protocol;
    stream_id = None;
    connection_id = t.connection.id;
  }

let read_request_head_with_timeout t ordinal =
  let timeout =
    if ordinal = 1 then t.config.server.timeouts.request_header_timeout
    else t.config.server.timeouts.idle_timeout
  in
  match timeout with
  | None -> `Read (read_request_head t)
  | Some duration -> (
      try
        `Read
          (t.with_timeout duration (fun () -> read_request_head t))
      with Eio.Time.Timeout -> `Timeout duration)

let handle_head_error t error =
  record_protocol_error t;
  write_default_error t (request_error_stub t) error

let request_from_head t head ordinal =
  request_of_head t head ordinal (Server.Body.empty ())
    (fun () -> Eta.Effect.pure Eta_http.Core.Header.empty)

let rec run_requests t ordinal handler =
  match read_request_head_with_timeout t ordinal with
  | `Timeout timeout ->
      if ordinal = 1 then
        handle_head_error t (request_timeout_error t (Some timeout))
      else ()
  | `Read (Error Clean_eof) -> ()
  | `Read (Error (Request_head_error error)) -> handle_head_error t error
  | `Read (Ok head) -> (
      match normalize_request_target t head with
      | Error error ->
          record_protocol_error t;
          write_default_error t (request_from_head t head ordinal) error
      | Ok head -> (
          match validate_authority t head with
          | Error error ->
              record_protocol_error t;
              write_default_error t (request_from_head t head ordinal) error
          | Ok () -> (
              match expect_continue t head with
              | Error error ->
                  record_protocol_error t;
                  let request = request_from_head t head ordinal in
                  write_default_error t request error
              | Ok continue_state -> (
                  match request_body t head continue_state with
                  | Error error ->
                      record_protocol_error t;
                      let request = request_from_head t head ordinal in
                      write_default_error t request error
                  | Ok (body, trailers, body_control) ->
                      Server_stats.H1.request_started t.stats;
                      let request = request_of_head t head ordinal body trailers in
                      let rt =
                        t.runtime_factory ~sw:t.sw ~connection:t.connection ()
                      in
                      let metrics = request_metrics t rt request in
                      t.current_metrics <- metrics;
                      Option.iter Server_metrics.request_started metrics;
                      let request_keep_alive = request_allows_keep_alive head in
                      let close_before_response =
                        (not request_keep_alive)
                        || not (body_can_reuse_before_response t body_control)
                      in
                      let response = run_handler t rt request handler in
                      let response_result =
                        write_response ~connection_close:close_before_response
                          ~rt t request response
                      in
                      let reusable =
                        match response_result with
                        | Ok { connection_close } ->
                            (not connection_close)
                            && request_keep_alive
                            && finish_request_body_for_reuse t rt body_control
                        | Error { error; response_started = false } ->
                            write_default_error t request error;
                            false
                        | Error { response_started = true; _ } -> false
                      in
                      Server_stats.H1.request_completed t.stats;
                      Option.iter Server_metrics.request_finished metrics;
                      t.current_metrics <- None;
                      if reusable then run_requests t (ordinal + 1) handler))))

let shutdown t _policy =
  if not t.closed then (
    Option.iter
      (fun metrics -> Server_metrics.shutdown_active metrics 1)
      t.connection_metrics;
    t.closed <- true;
    try Eio.Flow.shutdown t.flow `All with _ -> ())

let run ~sw ~clock ~flow ~connection ~config ~runtime_factory ?on_start
    ?on_close handler =
  validate_config config;
  let t =
    {
      sw;
      with_timeout =
        (fun duration f ->
          Eio.Time.with_timeout_exn clock
            (Eta.Duration.to_seconds_float duration)
            f);
      flow;
      connection;
      config;
      runtime_factory;
      stats = Server_stats.H1.create ();
      connection_metrics =
        (if config.server.enable_otel then
           Some
             (Server_metrics.connection
                ~runtime:(runtime_factory ~sw ~connection ())
                ~connection)
         else None);
      current_metrics = None;
      pending = Bytes.empty;
      pending_off = 0;
      pending_len = 0;
      closed = false;
    }
  in
  Option.iter
    (fun metrics -> Server_metrics.active_connections metrics 1)
    t.connection_metrics;
  Option.iter (fun on_start -> on_start t) on_start;
  Fun.protect
    ~finally:(fun () ->
      Option.iter
        (fun metrics -> Server_metrics.active_connections metrics 0)
        t.connection_metrics;
      Option.iter
        (fun metrics -> Server_metrics.shutdown_active metrics 0)
        t.connection_metrics;
      t.closed <- true;
      (try Eio.Flow.shutdown flow `All with _ -> ());
      Option.iter (fun on_close -> on_close (stats t)) on_close)
    (fun () -> run_requests t 1 handler)
