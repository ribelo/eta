module A = Eta_ai
module E = Eta.Effect
module H = Eta_http
module Json = A.Json
module Error = Xai_error

let provider_name = "xai"
let default_base_url = "https://api.x.ai"
let default_management_base_url = "https://management-api.x.ai"

let invalid message = Error (Error.Invalid_request message)
let decode_error ?raw_body message = Error (Error.Decode { message; raw_body })

let finite_float label value =
  match classify_float value with
  | FP_normal | FP_subnormal | FP_zero -> Ok value
  | FP_infinite | FP_nan -> invalid (label ^ " must be finite")

let utf8_scalar_count label value =
  let length = String.length value in
  let continuation index =
    index < length
    &&
    let byte = Char.code value.[index] in
    byte land 0xC0 = 0x80
  in
  let rec loop index count =
    if index = length then Ok count
    else
      let byte = Char.code value.[index] in
      if byte <= 0x7F then loop (index + 1) (count + 1)
      else if byte >= 0xC2 && byte <= 0xDF && continuation (index + 1) then
        loop (index + 2) (count + 1)
      else if
        byte = 0xE0 && index + 2 < length
        &&
        let second = Char.code value.[index + 1] in
        second >= 0xA0 && second <= 0xBF && continuation (index + 2)
      then loop (index + 3) (count + 1)
      else if
        byte >= 0xE1 && byte <= 0xEC && continuation (index + 1)
        && continuation (index + 2)
      then loop (index + 3) (count + 1)
      else if
        byte = 0xED && index + 2 < length
        &&
        let second = Char.code value.[index + 1] in
        second >= 0x80 && second <= 0x9F && continuation (index + 2)
      then loop (index + 3) (count + 1)
      else if
        byte >= 0xEE && byte <= 0xEF && continuation (index + 1)
        && continuation (index + 2)
      then loop (index + 3) (count + 1)
      else if
        byte = 0xF0 && index + 3 < length
        &&
        let second = Char.code value.[index + 1] in
        second >= 0x90 && second <= 0xBF && continuation (index + 2)
        && continuation (index + 3)
      then loop (index + 4) (count + 1)
      else if
        byte >= 0xF1 && byte <= 0xF3 && continuation (index + 1)
        && continuation (index + 2) && continuation (index + 3)
      then loop (index + 4) (count + 1)
      else if
        byte = 0xF4 && index + 3 < length
        &&
        let second = Char.code value.[index + 1] in
        second >= 0x80 && second <= 0x8F && continuation (index + 2)
        && continuation (index + 3)
      then loop (index + 4) (count + 1)
      else invalid (label ^ " must be valid UTF-8")
  in
  loop 0 0

let parse_json raw =
  match Json.parse raw with
  | Ok value -> Ok value
  | Error message -> decode_error ~raw_body:raw message

let required_string name json =
  match Json.string_member name json with
  | Some value -> Ok value
  | None -> decode_error (name ^ " is missing or is not a string")

let required_int name json =
  match Json.int_member name json with
  | Some value -> Ok value
  | None -> decode_error (name ^ " is missing or is not an integer")

let required_array name json =
  match Json.array_member name json with
  | Some value -> Ok value
  | None -> decode_error (name ^ " is missing or is not an array")

let result_map_all f values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest -> (
        match f value with
        | Ok mapped -> loop (mapped :: acc) rest
        | Error _ as error -> error)
  in
  loop [] values

let json_string_list values = Json.array (List.map Json.string values)

let int64_member name json =
  match Json.member name json with
  | Some (`Int value) -> Some (Int64.of_int value)
  | Some (`Intlit value) -> Int64.of_string_opt value
  | _ -> None

let float_member name json =
  match Json.member name json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | Some (`Intlit value) -> float_of_string_opt value
  | _ -> None

let bool_member name json =
  match Json.member name json with Some (`Bool value) -> Some value | _ -> None

let assoc_member name json =
  match Json.member name json with Some (`Assoc value) -> Some value | _ -> None

let raw_headers key =
  H.Core.Header.unsafe_of_list
    [
      ("Authorization", "Bearer " ^ Eta_redacted.value key);
      ("Content-Type", "application/json");
      ("Accept", "application/json");
    ]

let inference_headers (key : A.api_key) = raw_headers key
let management_headers key = raw_headers key

let join_url base_url path = A.join_url base_url path

let query_value value =
  let safe = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
    | _ -> false
  in
  let buffer = Buffer.create (String.length value) in
  String.iter
    (fun char ->
      if safe char then Buffer.add_char buffer char
      else Buffer.add_string buffer (Printf.sprintf "%%%02X" (Char.code char)))
    value;
  Buffer.contents buffer

let with_query uri values =
  let values =
    List.filter_map
      (fun (name, value) ->
        Option.map (fun value -> name ^ "=" ^ query_value value) value)
      values
  in
  match values with [] -> uri | _ -> uri ^ "?" ^ String.concat "&" values

let json_request ~headers ~base_url ~meth ~path ?json () =
  let body =
    match json with
    | None -> H.Request.Empty
    | Some json -> H.Request.Fixed [ Bytes.of_string (Json.to_string json) ]
  in
  H.Request.make ~headers ~body meth (join_url base_url path)

let content_type headers = H.Core.Header.get "content-type" headers

let error_type = function
  | Error.Http _ -> "http_error"
  | Error.Provider { payload = { code = Some code; _ }; _ } -> code
  | Error.Provider _ -> "provider_error"
  | Error.Unknown_response _ -> "unknown_response"
  | Error.Decode _ -> "decode_error"
  | Error.Invalid_request _ -> "invalid_request"

let authority_attrs base_url =
  match H.Core.Url.parse base_url with
  | Error _ -> []
  | Ok url ->
      [ ("server.address", H.Core.Url.host url) ]
      @
      match H.Core.Url.port url with
      | Some port -> [ ("server.port", string_of_int port) ]
      | None -> []

let with_span ?(telemetry = `Gen_ai) ~base_url ~operation ?model ?(attrs = [])
    eff =
  let attrs =
    (match telemetry with
    | `Gen_ai ->
        [
          ("gen_ai.operation.name", operation);
          ("gen_ai.provider.name", provider_name);
        ]
    | `Provider ->
        [
          ("eta_ai.operation.name", operation);
          ("eta_ai.provider.name", provider_name);
        ])
    @ authority_attrs base_url
    @
    (match model with
    | None -> []
    | Some model -> [ ("gen_ai.request.model", model) ])
    @ attrs
  in
  eff
  |> E.bind_error (fun error ->
         E.fail error |> E.annotate_all [ ("error.type", error_type error) ])
  |> E.annotate_all attrs
  |> E.named ~error_pp:Error.pp ~kind:Eta.Capabilities.Client
       (operation ^ " xai")

let read_body ?max_bytes body =
  H.Body.Stream.read_all ?max_bytes body
  |> E.bind_error (fun error -> E.fail (Error.Http error))

let perform_response_unspanned ?max_bytes client request =
  H.request client request
  |> A.suppress_provider_transport_observability
  |> E.bind_error (fun error -> E.fail (Error.Http error))
  |> E.bind (fun (response : H.Response.t) ->
         read_body ?max_bytes response.body
         |> E.bind (fun body ->
                if response.status >= 200 && response.status < 300 then
                  E.pure (body, response.headers)
                else
                  E.fail
                    (Error.decode ~status:response.status
                       ~headers:response.headers
                       (Bytes.to_string body))))

let perform_response ?max_bytes ?(telemetry = `Gen_ai) ~base_url ~operation
    ?model ?(attrs = []) client request =
  perform_response_unspanned ?max_bytes client request
  |> with_span ~telemetry ~base_url ~operation ?model ~attrs

let perform_json ?max_bytes ?(telemetry = `Gen_ai) ~base_url ~operation ?model
    ?(attrs = []) ?(result_attrs = fun _ -> []) client request decode =
  perform_response_unspanned ?max_bytes client request
  |> E.bind (fun (body, _) ->
         match decode (Bytes.to_string body) with
         | Ok value -> E.pure value |> E.annotate_all (result_attrs value)
         | Error error -> E.fail error)
  |> with_span ~telemetry ~base_url ~operation ?model ~attrs

let safe_disposition label value =
  if
    String.contains value '\r' || String.contains value '\n'
    || String.contains value '"'
  then invalid (label ^ " contains an invalid multipart character")
  else Ok value

let safe_header label value =
  if String.contains value '\r' || String.contains value '\n' then
    invalid (label ^ " contains an invalid multipart header character")
  else Ok value

let contains_substring value needle =
  let value_len = String.length value and needle_len = String.length needle in
  let rec loop index =
    if needle_len = 0 then true
    else if index + needle_len > value_len then false
    else if String.sub value index needle_len = needle then true
    else loop (index + 1)
  in
  loop 0

type multipart_part =
  | Field of string * string
  | File of {
      name : string;
      filename : string;
      content_type : string;
      data : bytes;
    }

let multipart ~label parts =
  let strings =
    List.concat_map
      (function
        | Field (name, value) -> [ name; value ]
        | File { name; filename; content_type; data = _ } ->
            [ name; filename; content_type ])
      parts
  in
  let data =
    parts
    |> List.filter_map (function File { data; _ } -> Some data | Field _ -> None)
  in
  let rec validate = function
    | [] -> Ok ()
    | Field (name, _) :: rest -> (
        match safe_disposition (label ^ " field name") name with
        | Error _ as error -> error
        | Ok _ -> validate rest)
    | File { name; filename; content_type; _ } :: rest -> (
        match safe_disposition (label ^ " file field") name with
        | Error _ as error -> error
        | Ok _ -> (
            match safe_disposition (label ^ " filename") filename with
            | Error _ as error -> error
            | Ok _ -> (
                match safe_header (label ^ " content type") content_type with
                | Error _ as error -> error
                | Ok _ -> validate rest)))
  in
  match validate parts with
  | Error _ as error -> error
  | Ok () ->
      let digest =
        data |> List.map Digest.bytes |> String.concat "" |> Digest.string
        |> Digest.to_hex
      in
      let rec choose suffix =
        let boundary =
          "eta-ai-xai-" ^ digest
          ^ if suffix = 0 then "" else "-" ^ string_of_int suffix
        in
        if
          List.exists (fun value -> contains_substring value boundary) strings
          || List.exists
               (fun bytes ->
                 contains_substring (Bytes.unsafe_to_string bytes) boundary)
               data
        then choose (suffix + 1)
        else boundary
      in
      let boundary = choose 0 in
      let chunks =
        parts
        |> List.concat_map (function
             | Field (name, value) ->
                 [
                   Bytes.of_string
                     ("--" ^ boundary
                    ^ "\r\nContent-Disposition: form-data; name=\"" ^ name
                    ^ "\"\r\n\r\n");
                   Bytes.of_string value;
                   Bytes.of_string "\r\n";
                 ]
             | File { name; filename; content_type; data } ->
                 [
                   Bytes.of_string
                     ("--" ^ boundary
                    ^ "\r\nContent-Disposition: form-data; name=\"" ^ name
                    ^ "\"; filename=\"" ^ filename ^ "\"\r\nContent-Type: "
                    ^ content_type ^ "\r\n\r\n");
                   data;
                   Bytes.of_string "\r\n";
                 ])
        |> fun chunks ->
        chunks @ [ Bytes.of_string ("--" ^ boundary ^ "--\r\n") ]
      in
      Ok (boundary, chunks)

let multipart_request ~headers ~base_url ~path boundary body =
  let headers =
    headers
    |> H.Core.Header.remove "content-type"
    |> H.Core.Header.unsafe_add "Content-Type"
         ("multipart/form-data; boundary=" ^ boundary)
  in
  H.Request.make ~headers ~body:(H.Request.Fixed body) "POST"
    (join_url base_url path)
