(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Server = Eta_http.Server

let find_failure cause =
  let rec loop = function
    | Eta.Cause.Fail error -> Some error
    | Die _ | Interrupt _ | Finalizer _ -> None
    | Sequential causes | Concurrent causes -> List.find_map loop causes
    | Suppressed { primary; _ } -> loop primary
  in
  loop cause

let request_error ~protocol request kind =
  Server.Error.make ~protocol ~method_:request.Server.Request.method_
    ~target:request.target kind

let handler_timeout_error ~protocol request timeout =
  request_error ~protocol request
    (Handler_timeout { timeout_ms = Option.map Eta.Duration.to_ms timeout })

let response_body_timeout_error ~protocol request timeout =
  request_error ~protocol request
    (Response_body_timeout { timeout_ms = Option.map Eta.Duration.to_ms timeout })

let handler_exception_error ~protocol request exn =
  request_error ~protocol request
    (Handler_failed { message = Printexc.to_string exn })

let handler_cause_error ~protocol request cause =
  match find_failure cause with
  | Some error -> error
  | None ->
      request_error ~protocol request
        (Handler_failed
           { message = Format.asprintf "%a" (Eta.Cause.pp Server.Error.pp) cause })

let fallback_error_response ~protocol request cause =
  Server.Handler.default_error_response
    (handler_cause_error ~protocol request cause)

let fenced_handler_effect ~protocol ~enable_otel ~emit_url_full request handler =
  let handler request =
    try handler request with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Eta.Effect.fail (handler_exception_error ~protocol request exn)
  in
  try
    Eta_http.Observability.Server.Tracer.request ~enabled:enable_otel
      ~emit_url_full handler request
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Eta.Effect.fail (handler_exception_error ~protocol request exn)
