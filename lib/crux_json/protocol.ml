module String_set = Set.Make (String)

include Protocol_model

let json_fields frame =
  let common = [ ("seq", `Int frame.seq); ("tag", `String (tag frame.body)) ] in
  let fields =
    match frame.body with
    | Deliver_output { reason; payload } ->
        [ ("reason", `String (delivery_reason_to_string reason));
          ("output", `String (encode_bytes payload)) ]
    | Notify_crash { failure } ->
        [ ("failure", `String (encode_bytes failure)) ]
    | Invoke_endpoint { handle; payload }
    | Start_request { handle; payload } ->
        [ ("handle", `String (encode_bytes handle));
          ("payload", `String (encode_bytes payload)) ]
    | Dispatch_request { request; operation; payload } ->
        [ ("request", `String (encode_bytes request));
          ("operation", `String operation);
          ("payload", `String (encode_bytes payload)) ]
    | Resolve_request { request; payload }
    | Request_resolved { request; payload } ->
        [ ("request", `String (encode_bytes request));
          ("payload", `String (encode_bytes payload)) ]
    | Cancel_request { request } ->
        [ ("request", `String (encode_bytes request)) ]
    | Request_closed { request; reason } ->
        [ ("request", `String (encode_bytes request));
          ("reason", `String (reason_to_string reason)) ]
    | Endpoint_result { reply_to; outcome } ->
        [ ("reply_to", `Int reply_to);
          ("outcome", `String (endpoint_outcome_to_string outcome)) ]
    | Request_start_result { reply_to; outcome } ->
        let outcome, extra = request_start_outcome_to_fields outcome in
        [ ("reply_to", `Int reply_to); ("outcome", `String outcome) ]
        @ (match extra with None -> [] | Some (name, value) -> [ (name, `String value) ])
    | Request_dispatch_result { reply_to; outcome } ->
        [ ("reply_to", `Int reply_to);
          ("accepted", `Bool (outcome = Dispatch_accepted)) ]
    | Request_resolve_result { reply_to; outcome } ->
        [ ("reply_to", `Int reply_to);
          ("outcome", `String (resolve_outcome_to_string outcome)) ]
    | Request_cancel_result { reply_to; outcome } ->
        [ ("reply_to", `Int reply_to);
          ("outcome", `String (cancel_outcome_to_string outcome)) ]
    | Output_result { reply_to; outcome }
    | Crash_result { reply_to; outcome } ->
        let outcome, message = callback_outcome_to_fields outcome in
        [ ("reply_to", `Int reply_to); ("outcome", `String outcome) ]
        @ (match message with None -> [] | Some value -> [ ("message", `String value) ])
  in
  common @ fields

let encode_json frame =
  Yojson.Safe.to_string (`Assoc (json_fields frame))

let duplicate_name fields =
  let rec loop seen = function
    | [] -> None
    | (name, _) :: _ when String_set.mem name seen -> Some name
    | (name, _) :: rest -> loop (String_set.add name seen) rest
  in
  loop String_set.empty fields

let exact_fields expected fields =
  match duplicate_name fields with
  | Some name -> Error ("duplicate field: " ^ name)
  | None ->
      let actual = List.map fst fields |> String_set.of_list in
      let expected = String_set.of_list expected in
      if not (String_set.equal actual expected) then
        let unknown = String_set.diff actual expected |> String_set.elements in
        let missing = String_set.diff expected actual |> String_set.elements in
        let parts =
          (if unknown = [] then [] else [ "unknown=" ^ String.concat "," unknown ])
          @ if missing = [] then [] else [ "missing=" ^ String.concat "," missing ]
        in
        Error ("invalid fields: " ^ String.concat " " parts)
      else Ok ()

let member name fields = List.assoc name fields

let int_member name fields =
  match member name fields with
  | `Int value when value >= 0 && value <= max_uint32 -> Ok value
  | _ -> Error (name ^ " must be an unsigned 32-bit integer")

let bool_member name fields =
  match member name fields with
  | `Bool value -> Ok value
  | _ -> Error (name ^ " must be a boolean")

let string_member name fields =
  match member name fields with
  | `String value -> Ok value
  | _ -> Error (name ^ " must be a string")

let bytes_member name fields =
  match string_member name fields with
  | Error _ as error -> error
  | Ok value -> decode_bytes value

let decode_json ~max_frame_bytes input =
  if max_frame_bytes <= 0 then invalid_arg "max_frame_bytes must be positive";
  if String.length input > max_frame_bytes then Error "frame exceeds max_frame_bytes"
  else
    try
      match Yojson.Safe.from_string input with
      | `Assoc fields ->
          let* seq =
            match List.assoc_opt "seq" fields with
            | Some (`Int value) when value >= 0 && value <= max_uint32 ->
                Ok value
            | _ -> Error "seq must be an unsigned 32-bit integer"
          in
          let* frame_tag =
            match List.assoc_opt "tag" fields with
            | Some (`String value) -> Ok value
            | _ -> Error "tag must be a string"
          in
          let finish expected make =
            let* () = exact_fields ("seq" :: "tag" :: expected) fields in
            let* body = make () in
            Ok { seq; body }
          in
          (match frame_tag with
          | "output.deliver" ->
              finish [ "reason"; "output" ] (fun () ->
                let* raw_reason = string_member "reason" fields in
                let* reason = delivery_reason_of_string raw_reason in
                let* payload = bytes_member "output" fields in
                Ok (Deliver_output { reason; payload }))
          | "crash.notify" ->
              finish [ "failure" ] (fun () ->
                let* failure = bytes_member "failure" fields in
                Ok (Notify_crash { failure }))
          | "endpoint.invoke" ->
              finish [ "handle"; "payload" ] (fun () ->
                let* handle = bytes_member "handle" fields in
                let* payload = bytes_member "payload" fields in
                Ok (Invoke_endpoint { handle; payload }))
          | "request.start" ->
              finish [ "handle"; "payload" ] (fun () ->
                let* handle = bytes_member "handle" fields in
                let* payload = bytes_member "payload" fields in
                Ok (Start_request { handle; payload }))
          | "request.dispatch" ->
              finish [ "request"; "operation"; "payload" ] (fun () ->
                let* request = bytes_member "request" fields in
                let* operation = string_member "operation" fields in
                let* payload = bytes_member "payload" fields in
                Ok (Dispatch_request { request; operation; payload }))
          | "request.resolve" ->
              finish [ "request"; "payload" ] (fun () ->
                let* request = bytes_member "request" fields in
                let* payload = bytes_member "payload" fields in
                Ok (Resolve_request { request; payload }))
          | "request.cancel" ->
              finish [ "request" ] (fun () ->
                let* request = bytes_member "request" fields in
                Ok (Cancel_request { request }))
          | "request.resolved" ->
              finish [ "request"; "payload" ] (fun () ->
                let* request = bytes_member "request" fields in
                let* payload = bytes_member "payload" fields in
                Ok (Request_resolved { request; payload }))
          | "request.closed" ->
              finish [ "request"; "reason" ] (fun () ->
                let* request = bytes_member "request" fields in
                let* raw_reason = string_member "reason" fields in
                let* reason = reason_of_string raw_reason in
                Ok (Request_closed { request; reason }))
          | "endpoint.result" ->
              finish [ "reply_to"; "outcome" ] (fun () ->
                let* reply_to = int_member "reply_to" fields in
                let* raw_outcome = string_member "outcome" fields in
                let* outcome = endpoint_outcome_of_string raw_outcome in
                Ok (Endpoint_result { reply_to; outcome }))
          | "request.start_result" ->
              let* raw_outcome = string_member "outcome" fields in
              (match raw_outcome with
              | "started" ->
                  finish [ "reply_to"; "outcome"; "request" ] (fun () ->
                    let* reply_to = int_member "reply_to" fields in
                    let* request = bytes_member "request" fields in
                    Ok (Request_start_result
                          { reply_to; outcome = Request_started request }))
              | "closed" ->
                  finish [ "reply_to"; "outcome"; "reason" ] (fun () ->
                    let* reply_to = int_member "reply_to" fields in
                    let* raw_reason = string_member "reason" fields in
                    let* reason = reason_of_string raw_reason in
                    Ok (Request_start_result
                          { reply_to; outcome = Start_closed reason }))
              | value ->
                  finish [ "reply_to"; "outcome" ] (fun () ->
                    let* reply_to = int_member "reply_to" fields in
                    let* outcome =
                      match value with
                      | "request_capacity_full" -> Ok Start_request_capacity_full
                      | "ingress_capacity_full" -> Ok Start_ingress_capacity_full
                      | "ingress_closed" -> Ok Start_ingress_closed
                      | "malformed_handle" -> Ok Start_malformed_handle
                      | "unknown_handle" -> Ok Start_unknown_handle
                      | "stale_handle" -> Ok Start_stale_handle
                      | "revoked_handle" -> Ok Start_revoked_handle
                      | "malformed_payload" -> Ok Start_malformed_payload
                      | value -> Error ("unknown request start outcome: " ^ value)
                    in
                    Ok (Request_start_result { reply_to; outcome })))
          | "request.dispatch_result" ->
              finish [ "reply_to"; "accepted" ] (fun () ->
                let* reply_to = int_member "reply_to" fields in
                let* accepted = bool_member "accepted" fields in
                let outcome =
                  if accepted then Dispatch_accepted else Dispatch_failed
                in
                Ok (Request_dispatch_result { reply_to; outcome }))
          | "request.resolve_result" ->
              finish [ "reply_to"; "outcome" ] (fun () ->
                let* reply_to = int_member "reply_to" fields in
                let* raw_outcome = string_member "outcome" fields in
                let* outcome = resolve_outcome_of_string raw_outcome in
                Ok (Request_resolve_result { reply_to; outcome }))
          | "request.cancel_result" ->
              finish [ "reply_to"; "outcome" ] (fun () ->
                let* reply_to = int_member "reply_to" fields in
                let* raw_outcome = string_member "outcome" fields in
                let* outcome = cancel_outcome_of_string raw_outcome in
                Ok (Request_cancel_result { reply_to; outcome }))
          | ("output.result" | "crash.result") as result_tag ->
              let* raw_outcome = string_member "outcome" fields in
              let finish_result expected outcome =
                finish expected (fun () ->
                  let* reply_to = int_member "reply_to" fields in
                  Ok (if String.equal result_tag "output.result" then
                    Output_result { reply_to; outcome }
                  else Crash_result { reply_to; outcome }))
              in
              (match raw_outcome with
              | "accepted" ->
                  finish_result [ "reply_to"; "outcome" ] Callback_accepted
              | "failed" ->
                  let* message = string_member "message" fields in
                  finish_result [ "reply_to"; "outcome"; "message" ]
                    (Callback_failed message)
              | value -> Error ("unknown callback outcome: " ^ value))
          | value -> Error ("unknown frame tag: " ^ value))
      | _ -> Error "frame must be a JSON object"
    with Yojson.Json_error message -> Error ("invalid JSON: " ^ message)
