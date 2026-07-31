(** Shared bounded WHATWG SSE lifecycle for OpenAI HTTP audio protocols. *)

module A = Eta_ai
module E = Eta.Effect
module H = Eta_http
module Json = A.Json

let ( let* ) = Result.bind
let defer thunk = E.sync thunk |> E.bind Fun.id

let default_max_buffer_bytes = 1024 * 1024
let default_max_json_bytes = 1024 * 1024
let default_max_pending_events = 256

type storage = bytes * bytes
type bom_state = Start | Ef | Ef_bb | Bom_done

type 'event t = {
  provider : A.provider;
  model : string;
  kind : string;
  attrs : (string * string) list;
  body : H.Body.Stream.t;
  decode : string -> Json.t -> ('event, Openai_error.t) result;
  max_buffer_bytes : int;
  max_json_bytes : int;
  max_pending_events : int;
  line : bytes;
  data : bytes;
  mutable line_length : int;
  mutable data_length : int;
  mutable framing_bytes : int;
  mutable has_data : bool;
  mutable after_cr : bool;
  mutable bom_state : bom_state;
  mutable pending : 'event list;
  mutable eof : bool;
  released : bool Atomic.t;
  active : bool Atomic.t;
}

let validate_bounds ~kind ~max_buffer_bytes ~max_json_bytes
    ~max_pending_events =
  if max_buffer_bytes <= 0 || max_json_bytes <= 0 || max_pending_events <= 0 then
    Common.invalid_request (kind ^ " bounds must all be positive")
  else Ok ()

let allocate ~kind ~max_buffer_bytes ~max_json_bytes =
  E.sync (fun () ->
      if
        max_buffer_bytes > Sys.max_string_length
        || max_json_bytes > Sys.max_string_length
      then
        Error
          (Openai_error.Invalid_request
             (kind ^ " byte bounds exceed the platform allocation limit"))
      else
        try Ok (Bytes.create max_buffer_bytes, Bytes.create max_json_bytes)
        with
        | Out_of_memory | Invalid_argument _ ->
            Error
              (Openai_error.Invalid_request
                 (kind ^ " parser storage cannot be allocated")))
  |> E.bind (function Ok value -> E.pure value | Error error -> E.fail error)

let make ~provider ~model ~kind ~attrs ~body ~decode ~max_buffer_bytes
    ~max_json_bytes ~max_pending_events (line, data) =
  {
    provider;
    model;
    kind;
    attrs;
    body;
    decode;
    max_buffer_bytes;
    max_json_bytes;
    max_pending_events;
    line;
    data;
    line_length = 0;
    data_length = 0;
    framing_bytes = 0;
    has_data = false;
    after_cr = false;
    bom_state = Start;
    pending = [];
    eof = false;
    released = Atomic.make false;
    active = Atomic.make false;
  }

let limit stream suffix limit actual =
  Openai_error.Limit_exceeded
    { kind = stream.kind ^ " " ^ suffix; limit; actual }

let over_limit_actual limit = if limit = max_int then max_int else limit + 1

let clear_parser stream =
  stream.line_length <- 0;
  stream.data_length <- 0;
  stream.framing_bytes <- 0;
  stream.has_data <- false;
  stream.after_cr <- false;
  stream.pending <- [];
  stream.eof <- true

let release stream =
  E.uninterruptible
    (E.sync (fun () -> Atomic.compare_and_set stream.released false true)
    |> E.bind (fun release ->
           if release then
             defer (fun () -> H.Body.Stream.discard stream.body)
             |> E.map_error (fun error -> Openai_error.Http error)
           else E.unit))

let cleanup stream =
  E.uninterruptible
    (E.sync (fun () -> clear_parser stream)
    |> E.bind (fun () -> release stream))

let with_operation stream operation thunk =
  (E.sync (fun () -> Atomic.compare_and_set stream.active false true)
  |> E.bind (fun acquired ->
         if not acquired then E.fail (Openai_error.Concurrent_use stream.kind)
         else
           defer thunk
           |> E.finally (E.sync (fun () -> Atomic.set stream.active false))))
  |> Common.with_provider_span stream.provider ~operation ~model:stream.model
       ~attrs:stream.attrs

let line_is_data stream colon =
  let field_length = Option.value colon ~default:stream.line_length in
  field_length = 4
  && Bytes.get stream.line 0 = 'd'
  && Bytes.get stream.line 1 = 'a'
  && Bytes.get stream.line 2 = 't'
  && Bytes.get stream.line 3 = 'a'

let append_data_byte stream byte =
  if stream.data_length >= stream.max_json_bytes then
    Error
      (limit stream "JSON bytes" stream.max_json_bytes
         (over_limit_actual stream.max_json_bytes))
  else (
    Bytes.set stream.data stream.data_length byte;
    stream.data_length <- stream.data_length + 1;
    Ok ())

let parse_line stream =
  if stream.line_length = 0 || Bytes.get stream.line 0 = ':' then Ok ()
  else
    let rec find_colon index =
      if index = stream.line_length then None
      else if Bytes.get stream.line index = ':' then Some index
      else find_colon (index + 1)
    in
    let colon = find_colon 0 in
    if not (line_is_data stream colon) then Ok ()
    else
      let* () =
        if stream.has_data then append_data_byte stream '\n' else Ok ()
      in
      stream.has_data <- true;
      let start =
        match colon with
        | None -> stream.line_length
        | Some colon ->
            let start = colon + 1 in
            if
              start < stream.line_length && Bytes.get stream.line start = ' '
            then start + 1
            else start
      in
      let rec copy index =
        if index = stream.line_length then Ok ()
        else
          let* () = append_data_byte stream (Bytes.get stream.line index) in
          copy (index + 1)
      in
      copy start

let decode_event stream =
  let raw = Bytes.sub_string stream.data 0 stream.data_length in
  match Json.parse raw with
  | Error message ->
      Error (Openai_error.Decode { message; raw_body = Some raw })
  | Ok (`Assoc _ as json) -> stream.decode raw json
  | Ok _ ->
      Error
        (Openai_error.Decode
           {
             message = stream.kind ^ " event must be a JSON object";
             raw_body = Some raw;
           })

let reset_event stream =
  stream.line_length <- 0;
  stream.data_length <- 0;
  stream.framing_bytes <- 0;
  stream.has_data <- false

let dispatch_event stream =
  if not stream.has_data then (
    reset_event stream;
    Ok ())
  else
    let pending = List.length stream.pending in
    if pending >= stream.max_pending_events then
      Error
        (limit stream "pending events" stream.max_pending_events
           (over_limit_actual stream.max_pending_events))
    else
      let* event = decode_event stream in
      stream.pending <- stream.pending @ [ event ];
      reset_event stream;
      Ok ()

let finish_line stream =
  let result =
    if stream.line_length = 0 then dispatch_event stream else parse_line stream
  in
  stream.line_length <- 0;
  result

let append_line_byte stream byte =
  if stream.framing_bytes >= stream.max_buffer_bytes then
    Error
      (limit stream "unframed bytes" stream.max_buffer_bytes
         (over_limit_actual stream.max_buffer_bytes))
  else (
    Bytes.set stream.line stream.line_length byte;
    stream.line_length <- stream.line_length + 1;
    stream.framing_bytes <- stream.framing_bytes + 1;
    Ok ())

let rec process_content_byte stream byte =
  if stream.after_cr then (
    stream.after_cr <- false;
    if byte = '\n' then Ok () else process_content_byte stream byte)
  else
    match byte with
    | '\r' ->
        stream.after_cr <- true;
        finish_line stream
    | '\n' -> finish_line stream
    | byte -> append_line_byte stream byte

let process_byte stream byte =
  match stream.bom_state with
  | Bom_done -> process_content_byte stream byte
  | Start ->
      if Char.code byte = 0xef then (
        stream.bom_state <- Ef;
        Ok ())
      else (
        stream.bom_state <- Bom_done;
        process_content_byte stream byte)
  | Ef ->
      if Char.code byte = 0xbb then (
        stream.bom_state <- Ef_bb;
        Ok ())
      else (
        stream.bom_state <- Bom_done;
        let* () = process_content_byte stream (Char.chr 0xef) in
        process_content_byte stream byte)
  | Ef_bb ->
      stream.bom_state <- Bom_done;
      if Char.code byte = 0xbf then Ok ()
      else
        let* () = process_content_byte stream (Char.chr 0xef) in
        let* () = process_content_byte stream (Char.chr 0xbb) in
        process_content_byte stream byte

let feed_chunk stream chunk =
  let length = Bytes.length chunk in
  let rec loop index =
    if index = length then Ok ()
    else
      let* () = process_byte stream (Bytes.get chunk index) in
      loop (index + 1)
  in
  loop 0

let rec read_step stream =
  match stream.pending with
  | event :: rest ->
      E.sync (fun () ->
          stream.pending <- rest;
          Some event)
  | [] when stream.eof -> E.pure None
  | [] ->
      defer (fun () -> H.Body.Stream.read stream.body)
      |> E.map_error (fun error -> Openai_error.Http error)
      |> E.bind (function
           | None ->
               E.sync (fun () ->
                   stream.eof <- true;
                   (* WHATWG discards an incomplete event at EOF. *)
                   clear_parser stream)
               |> E.bind (fun () -> release stream |> E.map (fun () -> None))
           | Some bytes ->
               E.sync (fun () -> feed_chunk stream bytes)
               |> E.bind (function
                    | Error error -> E.fail error
                    | Ok () -> read_step stream))

let read_unlocked stream =
  read_step stream
  |> E.on_exit (function
       | Eta.Exit.Ok _ -> E.unit
       | Eta.Exit.Error _ -> cleanup stream)

let read stream ~operation =
  with_operation stream operation (fun () -> read_unlocked stream)

let close stream ~operation =
  with_operation stream operation (fun () -> cleanup stream)
