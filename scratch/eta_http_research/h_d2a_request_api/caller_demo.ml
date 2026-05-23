open Eta

module Api = Request_api

type trace = string list

let ( let* ) effect f = Effect.bind f effect

let header_value name headers =
  headers
  |> List.find_opt (fun (key, _) -> String.lowercase_ascii key = name)
  |> Option.map snd
  |> Option.value ~default:""

let status_or_error req response =
  if response.Api.Response.status >= 200 && response.status < 300 then
    Effect.unit
  else
    Effect.fail
      (Error.make ~method_:req.Api.Request.method_ ~uri:req.uri
         (HTTP_status { status = response.status; headers = response.headers }))

let read_whole client req label =
  let* response = Api.request client req in
  let* () = status_or_error req response in
  let* body = Api.Stream.read_all response.body in
  let* trailers = response.trailers () in
  Effect.pure
    (Printf.sprintf "%s status=%d body=%s trailer=%s" label response.status body
       (header_value "x-demo-trailer" trailers))

let read_stream_then_discard client =
  let req = Api.Request.make "GET" "/stream" in
  let* response = Api.request client req in
  let* () = status_or_error req response in
  let* first = Api.Stream.read response.body in
  let* () = Api.Stream.discard response.body in
  let* trailers = response.trailers () in
  let chunk = Option.value first ~default:"<none>" in
  Effect.pure
    (Printf.sprintf "stream first=%s trailer=%s" chunk
       (header_value "x-demo-trailer" trailers))

let is_body_idle_timeout err =
  match err.Error.kind with
  | Response_body_idle_timeout _ -> true
  | _ -> false

let cancel_mid_body client =
  let req = Api.Request.make "GET" "/slow" in
  let timeout_error =
    Error.make ~method_:req.method_ ~uri:req.uri
      (Response_body_idle_timeout { timeout_ms = Some 5 })
  in
  let* response = Api.request client req in
  let attempt =
    Api.Stream.read_all response.body
    |> Effect.timeout_as (Duration.ms 5) ~on_timeout:timeout_error
    |> Effect.map (fun body -> Ok body)
    |> Effect.catch (fun err -> Effect.pure (Error err))
  in
  let* result = attempt in
  match result with
  | Ok body ->
      Effect.fail
        (Error.make ~method_:req.method_ ~uri:req.uri
           (Decode_error
              { codec = "caller_demo"; message = "expected cancellation, got " ^ body }))
  | Error err when is_body_idle_timeout err ->
      Effect.pure "slow cancelled=response_body_idle_timeout"
  | Error err -> Effect.fail err

let run client =
  let small_req = Api.Request.make "GET" "/small" in
  let echo_req =
    Api.Request.make ~body:(Fixed [ "alpha"; "beta" ]) "POST" "/echo"
  in
  let* small = read_whole client small_req "small" in
  let* echo = read_whole client echo_req "echo" in
  let* stream = read_stream_then_discard client in
  let* cancelled = cancel_mid_body client in
  Effect.pure [ small; echo; stream; cancelled ]
