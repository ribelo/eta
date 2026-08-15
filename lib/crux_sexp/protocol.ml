include Protocol_model

let atom value = if String.equal value "" then "\"\"" else value
let list values = "(" ^ String.concat " " values ^ ")"

let encode_sexp frame =
  let fields =
    match frame.body with
    | Deliver_projection { reason; content } ->
        let content_name, count, items =
          match content with
          | Projection_updates updates ->
              let fields =
                List.concat_map
                  (function
                    | Projection_attached entry ->
                        [
                          "attached";
                          entry.kind;
                          encode_bytes entry.key;
                          uint64_to_string entry.incarnation;
                          encode_bytes entry.value;
                        ]
                    | Projection_changed entry ->
                        [
                          "changed";
                          entry.kind;
                          encode_bytes entry.key;
                          uint64_to_string entry.incarnation;
                          encode_bytes entry.value;
                        ]
                    | Projection_removed { kind; key; incarnation } ->
                        [
                          "removed";
                          kind;
                          encode_bytes key;
                          uint64_to_string incarnation;
                        ])
                  updates
              in
              ("updates", List.length updates, fields)
          | Projection_bootstrap entries ->
              let fields =
                List.concat_map
                  (fun entry ->
                    [
                      entry.kind;
                      encode_bytes entry.key;
                      uint64_to_string entry.incarnation;
                      encode_bytes entry.value;
                    ])
                  entries
              in
              ("bootstrap", List.length entries, fields)
        in
        List.map atom
          (delivery_reason_to_string reason :: content_name
         :: string_of_int count :: items)
    | Notify_crash { failure } -> [ atom (encode_bytes failure) ]
    | Invoke_endpoint { handle; payload }
    | Start_request { handle; payload } ->
        [ atom (encode_bytes handle); atom (encode_bytes payload) ]
    | Dispatch_request { request; operation; payload } ->
        [ atom (encode_bytes request); atom operation; atom (encode_bytes payload) ]
    | Resolve_request { request; payload }
    | Request_resolved { request; payload } ->
        [ atom (encode_bytes request); atom (encode_bytes payload) ]
    | Cancel_request { request } -> [ atom (encode_bytes request) ]
    | Request_closed { request; reason } ->
        [ atom (encode_bytes request); atom (reason_to_string reason) ]
    | Endpoint_result { reply_to; outcome } ->
        [ atom (string_of_int reply_to); atom (endpoint_outcome_to_string outcome) ]
    | Request_start_result { reply_to; outcome } ->
        let outcome, extra = request_start_outcome_to_fields outcome in
        [ atom (string_of_int reply_to); atom outcome ]
        @ (match extra with None -> [] | Some (_, value) -> [ atom value ])
    | Request_dispatch_result { reply_to; outcome } ->
        [ atom (string_of_int reply_to);
          atom (if outcome = Dispatch_accepted then "true" else "false") ]
    | Request_resolve_result { reply_to; outcome } ->
        [ atom (string_of_int reply_to); atom (resolve_outcome_to_string outcome) ]
    | Request_cancel_result { reply_to; outcome } ->
        [ atom (string_of_int reply_to); atom (cancel_outcome_to_string outcome) ]
    | Projection_result { reply_to; outcome }
    | Crash_result { reply_to; outcome } ->
        let outcome, message = callback_outcome_to_fields outcome in
        [ atom (string_of_int reply_to); atom outcome ]
        @ (match message with None -> [] | Some value -> [ atom (encode_bytes value) ])
  in
  list (atom (string_of_int frame.seq) :: atom (tag frame.body) :: fields)

let parse_flat_sexp input =
  let length = String.length input in
  if length < 2 || input.[0] <> '(' || input.[length - 1] <> ')' then
    Error "frame must be a flat S-expression list"
  else
    let body = String.sub input 1 (length - 2) in
    if String.equal body "" then Ok []
    else
      let atoms = String.split_on_char ' ' body in
      if List.exists
          (fun value ->
            String.equal value "" || String.contains value '('
            || String.contains value ')')
          atoms
      then Error "S-expression contains an invalid atom"
      else Ok atoms

let decode_sexp ~max_frame_bytes input =
  if max_frame_bytes <= 0 then invalid_arg "max_frame_bytes must be positive";
  if String.length input > max_frame_bytes then Error "frame exceeds max_frame_bytes"
  else
    let parse_seq value =
      match int_of_string_opt value with
      | Some value when value >= 0 && value <= max_uint32 -> Ok value
      | _ -> Error "seq must be an unsigned 32-bit integer"
    in
    let bytes value =
      decode_bytes (if String.equal value "\"\"" then "" else value)
    in
    let parse_count value =
      if
        String.equal value ""
        || (String.length value > 1 && value.[0] = '0')
        || not
             (String.for_all
                (function '0' .. '9' -> true | _ -> false)
                value)
      then Error "count must be a canonical unsigned decimal"
      else
        match int_of_string_opt value with
        | Some count when count >= 0 -> Ok count
        | _ -> Error "count exceeds the supported range"
    in
    let parse_incarnation value =
      if
        String.equal value ""
        || String.equal value "0"
        || (String.length value > 1 && value.[0] = '0')
        || not
             (String.for_all
                (function '0' .. '9' -> true | _ -> false)
                value)
      then Error "incarnation must be a nonzero canonical unsigned decimal"
      else
        try Ok (Int64.of_string ("0u" ^ value))
        with Failure _ ->
          Error "incarnation exceeds unsigned 64-bit range"
    in
    let rec bootstrap_items count reversed = function
      | rest when count = 0 ->
          if rest = [] then Ok (List.rev reversed)
          else Error "projection bootstrap item count mismatch"
      | kind :: key :: incarnation :: value :: rest ->
          let* key = bytes key in
          let* incarnation = parse_incarnation incarnation in
          let* value = bytes value in
          bootstrap_items (count - 1)
            ({ kind; key; incarnation; value } :: reversed)
            rest
      | _ -> Error "projection bootstrap item count mismatch"
    in
    let rec update_items count reversed = function
      | rest when count = 0 ->
          if rest = [] then Ok (List.rev reversed)
          else Error "projection update item count mismatch"
      | ("attached" | "changed" as update)
        :: kind :: key :: incarnation :: value :: rest ->
          let* key = bytes key in
          let* incarnation = parse_incarnation incarnation in
          let* value = bytes value in
          let entry = { kind; key; incarnation; value } in
          let update =
            if String.equal update "attached" then
              Projection_attached entry
            else Projection_changed entry
          in
          update_items (count - 1) (update :: reversed) rest
      | "removed" :: kind :: key :: incarnation :: rest ->
          let* key = bytes key in
          let* incarnation = parse_incarnation incarnation in
          update_items (count - 1)
            (Projection_removed { kind; key; incarnation } :: reversed)
            rest
      | _ -> Error "projection update item count mismatch"
    in
    match parse_flat_sexp input with
      | Ok (raw_seq :: frame_tag :: args) ->
          let* seq = parse_seq raw_seq in
          let make body = Ok { seq; body } in
          (match frame_tag, args with
          | "projection.deliver",
            reason :: content_name :: raw_count :: items ->
              let* reason = delivery_reason_of_string reason in
              let* count = parse_count raw_count in
              (match reason, content_name with
              | Advancement, "updates" ->
                  let* updates = update_items count [] items in
                  make
                    (Deliver_projection
                       {
                         reason;
                         content = Projection_updates updates;
                       })
              | Session_replacement, "bootstrap" ->
                  let* entries = bootstrap_items count [] items in
                  make
                    (Deliver_projection
                       {
                         reason;
                         content = Projection_bootstrap entries;
                       })
              | _ -> Error "invalid projection reason and content pairing")
          | "crash.notify", [ failure ] ->
              let* failure = bytes failure in
              make (Notify_crash { failure })
          | "endpoint.invoke", [ handle; payload ] ->
              let* handle = bytes handle in
              let* payload = bytes payload in
              make (Invoke_endpoint { handle; payload })
          | "request.start", [ handle; payload ] ->
              let* handle = bytes handle in
              let* payload = bytes payload in
              make (Start_request { handle; payload })
          | "request.dispatch",
            [ request; operation; payload ] ->
              let* request = bytes request in
              let* payload = bytes payload in
              make (Dispatch_request { request; operation; payload })
          | "request.resolve", [ request; payload ] ->
              let* request = bytes request in
              let* payload = bytes payload in
              make (Resolve_request { request; payload })
          | "request.cancel", [ request ] ->
              let* request = bytes request in
              make (Cancel_request { request })
          | "request.resolved", [ request; payload ] ->
              let* request = bytes request in
              let* payload = bytes payload in
              make (Request_resolved { request; payload })
          | "request.closed", [ request; raw_reason ] ->
              let* request = bytes request in
              let* reason = reason_of_string raw_reason in
              make (Request_closed { request; reason })
          | "endpoint.result", [ raw_reply_to; outcome ] ->
              let* reply_to = parse_seq raw_reply_to in
              let* outcome = endpoint_outcome_of_string outcome in
              make (Endpoint_result { reply_to; outcome })
          | "request.start_result",
            [ raw_reply_to; "started";
              request ] ->
              let* reply_to = parse_seq raw_reply_to in
              let* request = bytes request in
              make (Request_start_result
                { reply_to; outcome = Request_started request })
          | "request.start_result",
            [ raw_reply_to; "closed";
              reason ] ->
              let* reply_to = parse_seq raw_reply_to in
              let* reason = reason_of_string reason in
              make (Request_start_result
                { reply_to; outcome = Start_closed reason })
          | "request.start_result",
            [ raw_reply_to; raw_outcome ] ->
              let* reply_to = parse_seq raw_reply_to in
              let* outcome =
                match raw_outcome with
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
              make (Request_start_result { reply_to; outcome })
          | "request.dispatch_result", [ raw_reply_to; accepted ] ->
              let* reply_to = parse_seq raw_reply_to in
              let* outcome =
                match accepted with
                | "true" -> Ok Dispatch_accepted
                | "false" -> Ok Dispatch_failed
                | _ -> Error "accepted must be true or false"
              in
              make (Request_dispatch_result { reply_to; outcome })
          | "request.resolve_result", [ raw_reply_to; outcome ] ->
              let* reply_to = parse_seq raw_reply_to in
              let* outcome = resolve_outcome_of_string outcome in
              make (Request_resolve_result { reply_to; outcome })
          | "request.cancel_result", [ raw_reply_to; outcome ] ->
              let* reply_to = parse_seq raw_reply_to in
              let* outcome = cancel_outcome_of_string outcome in
              make (Request_cancel_result { reply_to; outcome })
          | ("projection.result" | "crash.result") as result_tag,
            [ raw_reply_to; "accepted" ] ->
              let* reply_to = parse_seq raw_reply_to in
              make (if String.equal result_tag "projection.result" then
                Projection_result { reply_to; outcome = Callback_accepted }
              else Crash_result { reply_to; outcome = Callback_accepted })
          | ("projection.result" | "crash.result") as result_tag,
            [ raw_reply_to; "failed";
              message ] ->
              let* reply_to = parse_seq raw_reply_to in
              let* message = bytes message in
              make (if String.equal result_tag "projection.result" then
                Projection_result { reply_to; outcome = Callback_failed message }
              else Crash_result { reply_to; outcome = Callback_failed message })
          | value, _ when List.mem value
              [ "projection.deliver"; "crash.notify"; "endpoint.invoke";
                "request.start"; "request.dispatch";
                "request.resolve"; "request.cancel"; "request.resolved";
                "request.closed"; "endpoint.result";
                "request.start_result"; "request.dispatch_result";
                "request.resolve_result"; "request.cancel_result";
                "projection.result"; "crash.result" ] ->
              Error ("invalid fields for frame tag: " ^ value)
          | value, _ -> Error ("unknown frame tag: " ^ value))
      | Ok _ -> Error "frame must contain a sequence and tag"
      | Error message -> Error message
