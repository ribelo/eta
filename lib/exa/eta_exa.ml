module E = Eta.Effect
module H = Eta_http

type api_key = string Eta_redacted.t

let api_key value = Eta_redacted.make ~label:"exa_api_key" value

type operation =
  | Search of string
  | Contents of string
  | Code_context of string
  | Agent_create of string
  | Agent_get of { id : string }
  | Agent_list of { limit : int option; cursor : string option }
  | Agent_cancel of { id : string }
  | Agent_events of {
      id : string;
      limit : int option;
      cursor : string option;
      last_event_id : string option;
    }

type response = {
  status : int;
  headers : H.Core.Header.t;
  body : string;
}

type error = Invalid_request of string | Http of H.Error.t

let max_response_body_bytes = 4 * 1024 * 1024

let error_message = function
  | Invalid_request message -> message
  | Http error -> H.Error.to_string error

let unreserved = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
  | _ -> false

let percent_encode value =
  let buffer = Buffer.create (String.length value) in
  String.iter
    (fun char ->
      if unreserved char then Buffer.add_char buffer char
      else Buffer.add_string buffer (Printf.sprintf "%%%02X" (Char.code char)))
    value;
  Buffer.contents buffer

let non_empty label value =
  let value = String.trim value in
  if value = "" then Error (Invalid_request (label ^ " is required"))
  else Ok value

let normalize_base_url value =
  let value = String.trim value in
  if value = "" then Error (Invalid_request "Exa base URL is required")
  else
    let rec trim_end index =
      if index >= 0 && value.[index] = '/' then trim_end (index - 1) else index
    in
    let index = trim_end (String.length value - 1) in
    if index < 0 then Error (Invalid_request "Exa base URL is invalid")
    else Ok (String.sub value 0 (index + 1))

let json_headers api_key =
  H.Core.Header.unsafe_of_list
    [
      ("x-api-key", Eta_redacted.value api_key);
      ("accept", "application/json");
      ("content-type", "application/json");
    ]

let get_headers ?last_event_id api_key =
  H.Core.Header.unsafe_of_list
    ([
       ("x-api-key", Eta_redacted.value api_key);
       ("accept", "application/json");
     ]
    @
    match last_event_id with
    | Some value -> [ ("last-event-id", value) ]
    | None -> [])

let query parameters =
  match parameters with
  | [] -> ""
  | parameters ->
      "?"
      ^ String.concat "&"
          (List.map
             (fun (name, value) -> name ^ "=" ^ percent_encode value)
             parameters)

let optional_non_empty label = function
  | None -> Ok None
  | Some value -> Result.map Option.some (non_empty label value)

let limit_parameter = function
  | None -> Ok []
  | Some value when value >= 1 && value <= 100 ->
      Ok [ ("limit", string_of_int value) ]
  | Some _ -> Error (Invalid_request "Exa list limit must be between 1 and 100")

let json_request ~api_key ~base_url ~path body =
  match non_empty "Exa JSON body" body with
  | Error _ as error -> error
  | Ok body ->
      Ok
        (H.Request.make ~headers:(json_headers api_key)
           ~body:(H.Request.Fixed [ Bytes.of_string body ]) "POST"
           (base_url ^ path))

let request ?(base_url = "https://api.exa.ai") ~api_key operation =
  match normalize_base_url base_url with
  | Error _ as error -> error
  | Ok base_url -> (
      match operation with
      | Search body -> json_request ~api_key ~base_url ~path:"/search" body
      | Contents body -> json_request ~api_key ~base_url ~path:"/contents" body
      | Code_context body ->
          json_request ~api_key ~base_url ~path:"/context" body
      | Agent_create body ->
          json_request ~api_key ~base_url ~path:"/agent/runs" body
      | Agent_get { id } ->
          Result.map
            (fun id ->
              H.Request.make ~headers:(get_headers api_key) "GET"
                (base_url ^ "/agent/runs/" ^ percent_encode id))
            (non_empty "Exa Agent run id" id)
      | Agent_cancel { id } ->
          Result.map
            (fun id ->
              H.Request.make ~headers:(get_headers api_key) "POST"
                (base_url ^ "/agent/runs/" ^ percent_encode id ^ "/cancel"))
            (non_empty "Exa Agent run id" id)
      | Agent_list { limit; cursor } -> (
          match
            (limit_parameter limit, optional_non_empty "Exa cursor" cursor)
          with
          | Error error, _ | _, Error error -> Error error
          | Ok limit, Ok cursor ->
              let parameters =
                limit
                @
                match cursor with
                | Some value -> [ ("cursor", value) ]
                | None -> []
              in
              Ok
                (H.Request.make ~headers:(get_headers api_key) "GET"
                   (base_url ^ "/agent/runs" ^ query parameters)))
      | Agent_events { id; limit; cursor; last_event_id } -> (
          match
            ( non_empty "Exa Agent run id" id,
              limit_parameter limit,
              optional_non_empty "Exa cursor" cursor,
              optional_non_empty "Exa last event id" last_event_id )
          with
          | Error error, _, _, _
          | _, Error error, _, _
          | _, _, Error error, _
          | _, _, _, Error error -> Error error
          | Ok id, Ok limit, Ok cursor, Ok last_event_id ->
              let parameters =
                limit
                @
                match cursor with
                | Some value -> [ ("cursor", value) ]
                | None -> []
              in
              Ok
                (H.Request.make
                   ~headers:(get_headers ?last_event_id api_key)
                   "GET"
                   (base_url ^ "/agent/runs/" ^ percent_encode id ^ "/events"
                  ^ query parameters))))

let run ?base_url client ~api_key operation =
  match request ?base_url ~api_key operation with
  | Error error -> E.fail error
  | Ok request ->
      H.Client.request client request
      |> E.map_error (fun error -> Http error)
      |> E.bind (fun (http_response : H.Response.t) ->
             H.Body.Stream.read_all ~max_bytes:max_response_body_bytes
               http_response.body
             |> E.map_error (fun error -> Http error)
             |> E.map (fun body ->
                    {
                      status = http_response.status;
                      headers = http_response.headers;
                      body = Bytes.to_string body;
                    }))
