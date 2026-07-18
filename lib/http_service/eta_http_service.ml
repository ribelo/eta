module S = Eta_http.Server
module Header = Eta_http.Core.Header

let error request kind =
  S.Error.make ~method_:request.S.Request.method_ ~target:request.target kind

let bad_request request message =
  error request (S.Error.Bad_request { message })

module Req = struct
  type t = {
    raw : S.Request.t;
    params : Eta_router.Params.t;
    route_pattern : string;
  }

  let make ~raw ~params ~route_pattern = { raw; params; route_pattern }
  let raw t = t.raw
  let params t = t.params
  let route_pattern t = t.route_pattern
  let param t name = Eta_router.Params.get t.params name
  let path t = t.raw.S.Request.path
  let target t = t.raw.target
  let query t = t.raw.query
  let method_ t = t.raw.method_
  let header t name = S.Request.header name t.raw
  let body t = t.raw.body
end

module Router = struct
  type route = Req.t -> (S.Response.t, S.Error.t) Eta.Effect.t

  type registration_error =
    | Empty_method_set of { pattern : string }
    | Invalid_method of { pattern : string; method_ : string }
    | Duplicate_route of { pattern : string; method_ : string option }
    | Ambiguous_any_route of { pattern : string }
    | Invalid_pattern of {
        pattern : string;
        reason : Eta_router.Error.insert;
      }

  type entry = {
    pattern : string;
    mutable any : route option;
    mutable methods : (string * route) list;
  }

  type t = {
    router : entry Eta_router.Router.t;
    entries : (string, entry) Hashtbl.t;
  }

  let pp_registration_error fmt = function
    | Empty_method_set { pattern } ->
        Format.fprintf fmt "empty method set for route pattern %S" pattern
    | Invalid_method { pattern; method_ } ->
        Format.fprintf fmt "invalid HTTP method %S for route pattern %S" method_
          pattern
    | Duplicate_route { pattern; method_ = None } ->
        Format.fprintf fmt "duplicate any-method route for pattern %S" pattern
    | Duplicate_route { pattern; method_ = Some method_ } ->
        Format.fprintf fmt "duplicate route for method %S and pattern %S" method_
          pattern
    | Ambiguous_any_route { pattern } ->
        Format.fprintf fmt
          "ambiguous method-specific and any-method routes for pattern %S"
          pattern
    | Invalid_pattern { pattern; reason = Eta_router.Error.Conflict message } ->
        Format.fprintf fmt "conflicting route pattern %S: %s" pattern message
    | Invalid_pattern { pattern; reason = Eta_router.Error.Invalid_route message } ->
        Format.fprintf fmt "invalid route pattern %S: %s" pattern message

  let create () = { router = Eta_router.Router.create (); entries = Hashtbl.create 32 }

  let ensure_entry t pattern =
    match Hashtbl.find_opt t.entries pattern with
    | Some entry -> Ok entry
    | None ->
        let entry = { pattern; any = None; methods = [] } in
        (match Eta_router.Router.insert t.router pattern entry with
        | Ok () ->
            Hashtbl.add t.entries pattern entry;
            Ok entry
        | Error reason -> Error (Invalid_pattern { pattern; reason }))

  let validate_methods ~pattern methods =
    match methods with
    | [] -> Error (Empty_method_set { pattern })
    | methods ->
        let rec loop seen = function
          | [] -> Ok ()
          | method_ :: rest ->
              if String.equal method_ "" then
                Error (Invalid_method { pattern; method_ })
              else if List.mem method_ seen then
                Error (Duplicate_route { pattern; method_ = Some method_ })
              else loop (method_ :: seen) rest
        in
        loop [] methods

  let add t ~methods pattern route =
    match validate_methods ~pattern methods with
    | Error _ as error -> error
    | Ok () -> (
        match ensure_entry t pattern with
        | Error _ as error -> error
        | Ok entry -> (
            match entry.any with
            | Some _ -> Error (Ambiguous_any_route { pattern })
            | None ->
                let duplicate =
                  List.find_opt
                    (fun method_ ->
                      List.exists
                        (fun (existing, _) -> String.equal existing method_)
                        entry.methods)
                    methods
                in
                (match duplicate with
                | Some method_ ->
                    Error (Duplicate_route { pattern; method_ = Some method_ })
                | None ->
                    entry.methods <-
                      entry.methods
                      @ List.map (fun method_ -> (method_, route)) methods;
                    Ok ())))

  let add_any t pattern route =
    match ensure_entry t pattern with
    | Error _ as error -> error
    | Ok entry ->
        if Option.is_some entry.any then
          Error (Duplicate_route { pattern; method_ = None })
        else if entry.methods <> [] then Error (Ambiguous_any_route { pattern })
        else (
          entry.any <- Some route;
          Ok ())

  let invalid_arg_error error =
    invalid_arg (Format.asprintf "%a" pp_registration_error error)

  let add_exn t ~methods pattern route =
    match add t ~methods pattern route with
    | Ok () -> ()
    | Error error -> invalid_arg_error error

  let add_any_exn t pattern route =
    match add_any t pattern route with
    | Ok () -> ()
    | Error error -> invalid_arg_error error

  let default_method_not_allowed ~allowed _request =
    let headers =
      Header.unsafe_of_list [ ("allow", String.concat ", " allowed) ]
    in
    Eta.Effect.pure
      (S.Response.text ~headers ~status:405 "method not allowed\n")

  let compile ?(not_found = S.Handler.route_not_found)
      ?(method_not_allowed = default_method_not_allowed) t =
    fun request ->
      match Eta_router.Router.at t.router request.S.Request.path with
      | Error Eta_router.Error.Not_found -> not_found request
      | Ok { Eta_router.Match.value = entry; params } -> (
          let req = Req.make ~raw:request ~params ~route_pattern:entry.pattern in
          match entry.any with
          | Some route -> route req
          | None -> (
              match
                List.assoc_opt request.S.Request.method_ entry.methods
              with
              | Some route -> route req
              | None ->
                  let allowed = List.map fst entry.methods in
                  method_not_allowed ~allowed request))
end

module Extractors = struct
  let bad_req req message = Eta.Effect.fail (bad_request (Req.raw req) message)

  module Param = struct
    let string name req =
      match Req.param req name with
      | Some value -> Eta.Effect.pure value
      | None -> bad_req req ("missing route parameter " ^ name)

    let int name req =
      let open Eta.Syntax in
      let* value = string name req in
      match int_of_string_opt value with
      | Some value -> Eta.Effect.pure value
      | None -> bad_req req ("route parameter " ^ name ^ " must be an integer")
  end

  module Query = struct
    type t = (string * string) list

    let split_once char text =
      match String.index_opt text char with
      | None -> (text, "")
      | Some index ->
          let left = String.sub text 0 index in
          let right =
            String.sub text (index + 1) (String.length text - index - 1)
          in
          (left, right)

    let hex_value = function
      | '0' .. '9' as c -> Some (Char.code c - Char.code '0')
      | 'a' .. 'f' as c -> Some (10 + Char.code c - Char.code 'a')
      | 'A' .. 'F' as c -> Some (10 + Char.code c - Char.code 'A')
      | _ -> None

    let percent_decode text =
      let len = String.length text in
      let buffer = Buffer.create len in
      let rec loop index =
        if index >= len then Ok (Buffer.contents buffer)
        else
          match text.[index] with
          | '+' ->
              Buffer.add_char buffer ' ';
              loop (index + 1)
          | '%' when index + 2 < len -> (
              match (hex_value text.[index + 1], hex_value text.[index + 2]) with
              | Some hi, Some lo ->
                  Buffer.add_char buffer (Char.chr ((hi lsl 4) + lo));
                  loop (index + 3)
              | _ -> Error "invalid percent-encoding in query string")
          | '%' -> Error "truncated percent-encoding in query string"
          | char ->
              Buffer.add_char buffer char;
              loop (index + 1)
      in
      loop 0

    let parse raw =
      match raw with
      | None -> Ok []
      | Some "" -> Ok []
      | Some query ->
          let rec loop acc = function
            | [] -> Ok (List.rev acc)
            | part :: rest ->
                let raw_key, raw_value = split_once '=' part in
                (match (percent_decode raw_key, percent_decode raw_value) with
                | Ok key, Ok value -> loop ((key, value) :: acc) rest
                | Error message, _ | _, Error message -> Error message)
          in
          loop [] (String.split_on_char '&' query)

    let all req =
      match parse (Req.query req) with
      | Ok query -> Eta.Effect.pure query
      | Error message -> bad_req req message

    let get name t = List.assoc_opt name t

    let get_all name t =
      List.filter_map
        (fun (key, value) -> if String.equal key name then Some value else None)
        t

    let single name req =
      let open Eta.Syntax in
      let+ params = all req in
      get name params

    let required name req =
      let open Eta.Syntax in
      let* value = single name req in
      match value with
      | Some value -> Eta.Effect.pure value
      | None -> bad_req req ("missing query parameter " ^ name)

    let int name req =
      let open Eta.Syntax in
      let* value = single name req in
      match value with
      | None -> Eta.Effect.pure None
      | Some value -> (
          match int_of_string_opt value with
          | Some value -> Eta.Effect.pure (Some value)
          | None -> bad_req req ("query parameter " ^ name ^ " must be an integer"))
  end

  let header name req = Eta.Effect.pure (Req.header req name)

  let body_text ~max_bytes req =
    let open Eta.Syntax in
    let request = Req.raw req in
    let map_body_error body_error =
      S.Error.make ~method_:request.S.Request.method_ ~target:request.target
        body_error.S.Error.kind
    in
    let* body =
      S.Body.read_all ~max_bytes (Req.body req) |> Eta.Effect.map_error map_body_error
    in
    Eta.Effect.pure (Bytes.to_string body)

  let json_body ~max_bytes decode req =
    let open Eta.Syntax in
    let* body = body_text ~max_bytes req in
    match Yojson.Safe.from_string body with
    | json -> (
        match decode json with
        | Ok value -> Eta.Effect.pure value
        | Error message -> bad_req req ("invalid JSON body: " ^ message))
    | exception Yojson.Json_error message -> bad_req req message

  let route1 e1 handler req =
    let open Eta.Syntax in
    let* a = e1 req in
    handler a

  let route2 e1 e2 handler req =
    let open Eta.Syntax in
    let* a = e1 req in
    let* b = e2 req in
    handler a b

  let route3 e1 e2 e3 handler req =
    let open Eta.Syntax in
    let* a = e1 req in
    let* b = e2 req in
    let* c = e3 req in
    handler a b c
end

module Json = struct
  let content_type = "application/json; charset=utf-8"
  let headers = Header.unsafe_of_list [ ("content-type", content_type) ]

  let response ?(status = 200) ?(newline = false) json =
    let body = Yojson.Safe.to_string json ^ if newline then "\n" else "" in
    S.Response.text ~status ~headers body
end

module Middleware = struct
  type t = S.handler -> S.handler

  type access_log_entry = {
    request_id : string;
    method_ : string;
    target : string;
    path : string;
    status : int option;
    error_class : string option;
  }

  let compose layers handler =
    List.fold_left (fun inner layer -> layer inner) handler layers

  let add_header name value response =
    let headers = Header.unsafe_add name value (S.Response.headers response) in
    S.Response.make ~headers ~status:(S.Response.status response)
      ~body:(S.Response.body response)
      ~trailers:(S.Response.trailers response)
      ()

  let request_id ?(header = "x-request-id") () inner request =
    let id =
      match S.Request.header header request with
      | Some id -> id
      | None -> Lazy.force request.S.Request.id
    in
    Eta.Effect.map (add_header header id) (inner request)

  let access_log ~log inner request =
    let open Eta.Syntax in
    let* result = Eta.Effect.to_result (inner request) in
    let entry =
      match result with
      | Ok response ->
          {
            request_id = Lazy.force request.S.Request.id;
            method_ = request.method_;
            target = request.target;
            path = request.path;
            status = Some (S.Response.status response);
            error_class = None;
          }
      | Error error ->
          {
            request_id = Lazy.force request.id;
            method_ = request.method_;
            target = request.target;
            path = request.path;
            status = S.Error.to_status error;
            error_class = Some (S.Error.error_class error);
          }
    in
    log entry;
    match result with
    | Ok response -> Eta.Effect.pure response
    | Error error -> Eta.Effect.fail error

  let timeout budget inner request =
    let on_timeout =
      S.Error.make ~method_:request.S.Request.method_ ~target:request.target
        (Handler_timeout { timeout_ms = Some (Eta.Duration.to_ms budget) })
    in
    Eta.Effect.timeout_as budget ~on_timeout (inner request)

  let admission semaphore inner request =
    Eta.Semaphore.with_permits semaphore 1 (fun () -> inner request)

  let cors ?(allow_origin = "*") ?(allow_methods = [ "GET"; "HEAD"; "POST"; "PUT"; "PATCH"; "DELETE"; "OPTIONS" ])
      ?(allow_headers = [ "authorization"; "content-type" ]) () inner request =
    let headers =
      [
        ("access-control-allow-origin", allow_origin);
        ("access-control-allow-methods", String.concat ", " allow_methods);
        ("access-control-allow-headers", String.concat ", " allow_headers);
      ]
    in
    let add_cors response =
      List.fold_left
        (fun response (name, value) -> add_header name value response)
        response headers
    in
    if String.equal request.S.Request.method_ "OPTIONS" then
      Eta.Effect.pure (add_cors (S.Response.empty ~status:204 ()))
    else Eta.Effect.map add_cors (inner request)

  let bearer_auth ~verify inner request =
    let token =
      match S.Request.header "authorization" request with
      | Some value ->
          let prefix = "Bearer " in
          if
            String.length value >= String.length prefix
            && String.equal prefix (String.sub value 0 (String.length prefix))
          then
            Some
              (String.sub value (String.length prefix)
                 (String.length value - String.length prefix))
          else None
      | None -> None
    in
    let open Eta.Syntax in
    let* () = verify ~token request in
    inner request
end
