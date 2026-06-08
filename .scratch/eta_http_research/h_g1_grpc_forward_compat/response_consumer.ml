module Error = Http.Error
module Header = Http.Core.Header
module Multiplexer = Http.H2.Multiplexer

let request_uri = "https://grpc.example.test/grpc.Service/Unary"

let request =
  H2.Request.create ~scheme:"https"
    ~headers:
      (H2.Headers.of_list
         [
           ":authority", "grpc.example.test";
           "content-type", "application/grpc+proto";
         ])
    `POST "/grpc.Service/Unary"

let closed_error =
  Error.make ~protocol:H2 ~method_:"POST" ~uri:request_uri
    (Connection_closed { during = Http_response })

let timeout_error =
  Error.make ~protocol:H2 ~method_:"POST" ~uri:request_uri
    (Total_request_timeout { timeout_ms = Some 1_000 })

let expect_ok label = function
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith
        (Format.asprintf "%s failed: %a" label (Eta.Cause.pp Error.pp) cause)

let make_trailers () =
  let promise, resolver = Eio.Promise.create () in
  let resolver_ref = ref (Some resolver) in
  let resolve value =
    match !resolver_ref with
    | None -> ()
    | Some resolver ->
        resolver_ref := None;
        Eio.Promise.resolve resolver value
  in
  let resolve_headers headers =
    match Http.H2.Security.validate_headers headers with
    | Some kind ->
        resolve (Error (Error.make ~protocol:H2 ~method_:"POST" ~uri:request_uri kind))
    | None -> resolve (Ok headers)
  in
  let resolve_empty () = resolve (Ok Header.empty) in
  let resolve_error error = resolve (Error error) in
  let trailers () =
    Eta.Effect.sync (fun () -> Eio.Promise.await promise)
    |> Eta.Effect.bind (function
         | Ok headers -> Eta.Effect.pure headers
         | Error error -> Eta.Effect.fail error)
  in
  (trailers, resolve_headers, resolve_empty, resolve_error)

let pp_client_error = function
  | `Malformed_response msg -> "malformed_response:" ^ msg
  | `Invalid_response_body_length _ -> "invalid_response_body_length"
  | `Protocol_error (code, msg) ->
      Format.asprintf "protocol_error:%a:%s" H2.Error_code.pp_hum code msg
  | `Exn exn -> "exn:" ^ Printexc.to_string exn

let open_response server =
  let result = ref None in
  let trailers, resolve_trailers, resolve_empty_trailers, resolve_trailer_error =
    make_trailers ()
  in
  let mux =
    Multiplexer.create ~error_handler:(fun error ->
        resolve_trailer_error
          (Error.make ~protocol:H2 ~method_:"POST" ~uri:request_uri
             (Connection_protocol_violation
                { kind = "connection"; message = pp_client_error error })))
      ()
  in
  let client = Multiplexer.client_connection mux in
  let pump () =
    Eta.Effect.sync (fun () ->
        if Fixture_grpc_server.pump_pair client server then Multiplexer.Read 1
        else Multiplexer.Eof 0)
  in
  let opened =
    Multiplexer.request mux ~tag:1
      ~trailers_handler:(fun headers -> resolve_trailers (H2.Headers.to_list headers))
      request
      ~error_handler:(fun _ error ->
        resolve_trailer_error
          (Error.make ~protocol:H2 ~method_:"POST" ~uri:request_uri
             (Connection_protocol_violation
                { kind = "stream"; message = pp_client_error error })))
      ~response_handler:(fun stream response body ->
        let status = H2.Status.to_code response.H2.Response.status in
        let headers = H2.Headers.to_list response.H2.Response.headers in
        let body =
          Multiplexer.body_stream ~closed_error ~on_eof:resolve_empty_trailers
            ~on_release:(fun _ ->
              resolve_trailer_error closed_error;
              Eta.Effect.unit)
            ~pump mux stream body
        in
        result := Some (Http.Response.make ~status ~headers ~trailers ~body ()))
  in
  let opened =
    match opened with
    | Ok opened -> opened
    | Error (Multiplexer.Admission_rejected _) ->
        failwith "request rejected by admission"
    | Error Multiplexer.Connection_closed -> failwith "connection closed before request"
    | Error (Multiplexer.Request_failed message) ->
        failwith ("request failed before response: " ^ message)
  in
  H2.Body.Writer.close opened.request_body;
  ignore (Fixture_grpc_server.pump_pair client server);
  match !result with
  | Some response -> response
  | None -> failwith "response handler did not run"

let run_one rt ~label ~grpc_status ~grpc_message =
  let server = Fixture_grpc_server.create ~grpc_status ~grpc_message () in
  let response = open_response server in
  let trailers =
    response.trailers ()
    |> Eta.Effect.timeout_as (Eta.Duration.seconds 1) ~on_timeout:timeout_error
    |> Eta.Runtime.run rt
    |> expect_ok (label ^ " trailers")
  in
  let body =
    Http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> expect_ok (label ^ " body")
  in
  let status =
    Header.get "grpc-status" trailers
    |> Option.value ~default:"<missing>"
  in
  if response.status <> 200 then
    failwith (Printf.sprintf "%s expected HTTP status 200" label);
  if not (String.equal status grpc_status) then
    failwith (Printf.sprintf "%s expected grpc-status %s, got %s" label grpc_status status);
  Printf.printf
    "h_g1_grpc label=%s http_status=%d body_bytes=%d grpc_status=%s grpc_message=%S\n%!"
    label response.status (Bytes.length body) status
    (Option.value ~default:"<missing>" (Header.get "grpc-message" trailers));
  body, trailers

let run env =
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let ok_body, ok_trailers =
    run_one rt ~label:"ok" ~grpc_status:"0" ~grpc_message:""
  in
  let unavailable_body, unavailable_trailers =
    run_one rt ~label:"unavailable" ~grpc_status:"14" ~grpc_message:"UNAVAILABLE"
  in
  if not (Bytes.equal ok_body unavailable_body) then
    failwith "gRPC status in trailers changed raw body bytes";
  if Header.get "grpc-status" ok_trailers <> Some "0" then
    failwith "missing OK grpc-status";
  if Header.get "grpc-status" unavailable_trailers <> Some "14" then
    failwith "missing unavailable grpc-status";
  Printf.printf
    "h_g1_grpc_forward_compat verdict=PASS raw_body_stable=true trailers_observable=true\n%!"

let () = Eio_main.run run
