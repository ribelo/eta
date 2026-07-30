module E = Eta.Effect
module Ws = Eta_http_eio.Ws.Client

type error =
  [ Ws.ws_error
  | `Decode of string
  | `Invalid_request of string
  | `Xai_error of Eta_ai_xai.Error.t
  ]

type t = {
  ws : Ws.t;
  send_mutex : Eio.Mutex.t;
  read_active : bool Atomic.t;
  closing : bool Atomic.t;
  closed : (string * string) list Eio.Promise.t;
  close_resolver : (string * string) list Eio.Promise.u;
  attrs_mutex : Eio.Mutex.t;
  mutable attrs : (string * string) list;
  started_ms : int;
  first_event : bool Atomic.t;
}

type sender = t

let bearer redacted =
  Eta_http.Core.Header.unsafe_of_list
    [ ("Authorization", "Bearer " ^ Eta_redacted.value redacted) ]

let headers (key : Eta_ai.api_key) = bearer key
let secret_headers secret =
  bearer (Eta_ai_xai.Realtime.client_secret_redacted secret)

let authority_attrs raw_url =
  match Eta_http.Core.Url.parse raw_url with
  | Error _ -> []
  | Ok url ->
      [
        ("gen_ai.operation.name", "connect");
        ("gen_ai.provider.name", "xai");
        ("server.address", Eta_http.Core.Url.host url);
      ]
      @
      match Eta_http.Core.Url.port url with
      | None -> []
      | Some port -> [ ("server.port", string_of_int port) ]

let record_attrs t attrs =
  Eio.Mutex.use_rw ~protect:false t.attrs_mutex (fun () ->
      t.attrs <- attrs @ t.attrs)

let is_closing t = Atomic.get t.closing

let finish ?error_type t =
  Option.iter (fun value -> record_attrs t [ ("error.type", value) ]) error_type;
  if Atomic.compare_and_set t.closing false true then
    let attrs =
      Eio.Mutex.use_rw ~protect:false t.attrs_mutex (fun () -> t.attrs)
    in
    Eio.Promise.resolve t.close_resolver attrs

let make ~operation ~attrs ~sw ~raw_url ws =
  let closed, close_resolver = Eio.Promise.create () in
  E.now_ms
  |> E.bind (fun started_ms ->
  let base_attrs =
    ("gen_ai.operation.name", operation)
    :: ("gen_ai.provider.name", "xai")
    :: List.filter
         (fun (name, _) ->
           name = "server.address" || name = "server.port")
         (authority_attrs raw_url)
  in
  let t =
    {
      ws;
      send_mutex = Eio.Mutex.create ();
      read_active = Atomic.make false;
      closing = Atomic.make false;
      closed;
      close_resolver;
      attrs_mutex = Eio.Mutex.create ();
      attrs = attrs @ base_attrs;
      started_ms;
      first_event = Atomic.make false;
    }
  in
  Eio.Switch.on_release sw (fun () -> finish t);
  Eta.Spi.daemon
    (E.sync (fun () -> Eio.Promise.await t.closed)
    |> E.bind (fun attrs -> E.unit |> E.annotate_all attrs)
    |> E.named ~kind:Eta.Capabilities.Client (operation ^ " xai"))
  |> E.map (fun () -> t))

let widen eff =
  E.bind_error
    (function
      | `Upgrade_failed failure ->
          let raw_body = Bytes.to_string failure.body in
          E.fail
            (`Xai_error
              (Eta_ai_xai.Error.decode ~status:failure.status
                 ~headers:failure.headers raw_body))
      | #Ws.ws_error as error -> E.fail (error :> error))
    eff

let error_type = function
  | `Connect _ -> "connect_error"
  | `Upgrade_failed _ -> "upgrade_error"
  | `Closed (code, _) -> "websocket_closed_" ^ string_of_int code
  | `Protocol _ -> "protocol_error"
  | `Timeout -> "timeout"
  | `Decode _ -> "decode_error"
  | `Invalid_request _ -> "invalid_request"
  | `Xai_error error ->
      (match Eta_ai_xai.Error.to_ai_error error with
      | Eta_ai.Provider_error { code = Some code; _ } -> code
      | _ -> "xai_error")

let terminal_send_error = function
  | `Connect _ | `Upgrade_failed _ | `Closed _ | `Timeout | `Xai_error _ ->
      true
  | `Protocol _ | `Decode _ | `Invalid_request _ -> false

let connect ?ca_file ?protocols ?(attrs = []) ~operation ~sw ~net
    ~(headers : Eta_http.Core.Header.t) raw_url =
  Ws.connect ?ca_file ?protocols ~sw ~net ~headers raw_url
  |> Eta_ai.suppress_provider_transport_observability
  |> widen
  |> E.bind (make ~operation ~attrs ~sw ~raw_url)

let connect_on_flow ?key ?protocols ?(attrs = []) ~operation ~sw ~flow
    ~(headers : Eta_http.Core.Header.t) url =
  Ws.connect_on_flow ?key ?protocols ~sw ~flow ~headers url
  |> Eta_ai.suppress_provider_transport_observability
  |> widen
  |> E.bind
       (make ~operation ~attrs ~sw
          ~raw_url:(Eta_http.Core.Url.to_string url))

let close ?error_type t =
  Option.iter (fun value -> record_attrs t [ ("error.type", value) ]) error_type;
  if Atomic.compare_and_set t.closing false true then (
    let attrs =
      Eio.Mutex.use_rw ~protect:false t.attrs_mutex (fun () -> t.attrs)
    in
    Eio.Promise.resolve t.close_resolver attrs;
    widen (Ws.close t.ws))
  else E.unit

let with_send t f =
  E.sync (fun () ->
      Eio.Mutex.lock t.send_mutex;
      if Atomic.get t.closing then (
        Eio.Mutex.unlock t.send_mutex;
        Error (`Closed (1000, "WebSocket is closing")))
      else Ok ())
  |> E.bind (function
       | Error error -> E.fail error
       | Ok () ->
           f t
           |> E.on_exit (fun exit ->
                  let unlock =
                    E.sync (fun () -> Eio.Mutex.unlock t.send_mutex)
                  in
                  match exit with
                  | Eta.Exit.Error cause
                    when Eta.Cause.is_interrupt_only cause
                         && not (is_closing t) ->
                      unlock |> E.finally (close ~error_type:"cancelled" t)
                  | Eta.Exit.Ok _ | Eta.Exit.Error _ -> unlock)
           |> E.bind_error (fun error ->
                  if terminal_send_error error then
                    E.fail error
                    |> E.finally (close ~error_type:(error_type error) t)
                  else E.fail error))

let send_text_locked t text = widen (Ws.send_text t.ws text)
let send_binary_locked t bytes = widen (Ws.send_binary t.ws bytes)
let send_text t text = with_send t (fun sender -> send_text_locked sender text)
let send_binary t bytes =
  with_send t (fun sender -> send_binary_locked sender bytes)

let read_message t =
  if not (Atomic.compare_and_set t.read_active false true) then
    E.fail (`Protocol "concurrent WebSocket event reads are not allowed")
  else
    (Ws.incoming t.ws |> Eta_stream.Stream.take 1 |> Eta_stream.run_collect
    |> widen)
    |> E.bind_error (fun error ->
           E.fail error
           |> E.finally (close ~error_type:(error_type error) t))
    |> E.bind (function
         | [] ->
             finish t;
             E.pure None
         | [ message ] ->
             if Atomic.compare_and_set t.first_event false true then
               E.now_ms
               |> E.map (fun now ->
                      record_attrs t
                        [
                          ( "gen_ai.response.time_to_first_chunk",
                            Printf.sprintf "%.6g"
                              (float_of_int (now - t.started_ms) /. 1000.) );
                        ];
                      Some message)
             else E.pure (Some message)
         | _ -> assert false)
    |> E.on_exit (fun exit ->
           let reset =
             E.sync (fun () -> Atomic.set t.read_active false)
           in
           match exit with
           | Eta.Exit.Ok _ -> reset
           | Eta.Exit.Error _ when not (is_closing t) ->
               reset
               |> E.finally (close ~error_type:"cancelled" t)
           | Eta.Exit.Error _ -> reset)

let trim_trailing_slash = Eta_ai.trim_trailing_slash

let rewrite_prefix value ~prefix ~replacement =
  replacement
  ^ String.sub value (String.length prefix)
      (String.length value - String.length prefix)

let ws_base_url endpoint =
  let base_url =
    Eta_ai_xai.Endpoint.inference_base_url endpoint |> trim_trailing_slash
  in
  if Eta.String_helpers.starts_with base_url ~prefix:"https://" then
    Ok (rewrite_prefix base_url ~prefix:"https://" ~replacement:"wss://")
  else Error (`Invalid_request "xAI WebSocket endpoints must use https/wss")

let percent_encode value =
  let safe = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
    | _ -> false
  in
  let out = Buffer.create (String.length value) in
  String.iter
    (fun char ->
      if safe char then Buffer.add_char out char
      else Buffer.add_string out (Printf.sprintf "%%%02X" (Char.code char)))
    value;
  Buffer.contents out

let query_url base path values =
  let query =
    List.map
      (fun (name, value) -> percent_encode name ^ "=" ^ percent_encode value)
      values
  in
  base ^ path
  ^ match query with [] -> "" | _ -> "?" ^ String.concat "&" query

let bool_string = string_of_bool
let float_string value = Printf.sprintf "%.17g" value
let xai_error_message error = Format.asprintf "%a" Eta_ai_xai.Error.pp error
