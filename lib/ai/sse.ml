open Types

type t = {
  provider : provider;
  body : Eta_http.Body.Stream.t;
  max_buffer_bytes : int;
  buffer : Buffer.t;
  mutable scan_pos : int;
  mutable pending : stream_event list;
  mutable eof : bool;
  mutable released : bool;
  active : bool Atomic.t;
}

let default_max_buffer_bytes = 1024 * 1024

let stream_of_body ?(max_buffer_bytes = default_max_buffer_bytes) provider body
    =
  if max_buffer_bytes <= 0 then invalid_arg "Eta_ai.stream_of_body";
  {
    provider;
    body;
    max_buffer_bytes;
    buffer = Buffer.create 4096;
    scan_pos = 0;
    pending = [];
    eof = false;
    released = false;
    active = Atomic.make false;
  }

let concurrent_use stream =
  Decode_error
    {
      provider = stream.provider.name;
      message = "concurrent SSE stream operation";
      raw = None;
    }

let with_operation stream effect =
  if not (Atomic.compare_and_set stream.active false true) then
    Eta.Effect.fail (concurrent_use stream)
  else (
    effect
    |> Eta.Effect.finally
         (Eta.Effect.sync (fun () -> Atomic.set stream.active false)))

let strip_trailing_cr line =
  let len = String.length line in
  if len > 0 && line.[len - 1] = '\r' then String.sub line 0 (len - 1)
  else line

let field_value line colon =
  let value_start = colon + 1 in
  if value_start < String.length line && line.[value_start] = ' ' then
    String.sub line (value_start + 1) (String.length line - value_start - 1)
  else String.sub line value_start (String.length line - value_start)

let parse_sse_record record =
  let event = ref None in
  let data = ref [] in
  record |> String.split_on_char '\n'
  |> List.iter (fun raw_line ->
         let line = strip_trailing_cr raw_line in
         if line <> "" && line.[0] <> ':' then
           match String.index_opt line ':' with
           | None -> ()
           | Some colon ->
               let field = String.sub line 0 colon in
               let value = field_value line colon in
               if String.equal field "event" then event := Some value
               else if String.equal field "data" then data := value :: !data);
  { event = !event; data = String.concat "\n" (List.rev !data) }

let find_sse_separator stream =
  let s = stream.buffer in
  let len = Buffer.length s in
  let rec loop index =
    if index >= len then None
    else if
      index + 1 < len && Buffer.nth s index = '\n'
      && Buffer.nth s (index + 1) = '\n'
    then
      Some (index, 2)
    else if
      index + 3 < len && Buffer.nth s index = '\r'
      && Buffer.nth s (index + 1) = '\n'
      && Buffer.nth s (index + 2) = '\r'
      && Buffer.nth s (index + 3) = '\n'
    then Some (index, 4)
    else loop (index + 1)
  in
  loop stream.scan_pos

let release_stream stream =
  if stream.released then Eta.Effect.unit
  else (
    stream.released <- true;
    Eta_http.Body.Stream.discard stream.body
    |> Eta.Effect.catch (fun error -> Eta.Effect.fail (Eta_http_error error)))

let close_stream_unlocked stream =
  stream.pending <- [];
  Buffer.clear stream.buffer;
  stream.scan_pos <- 0;
  stream.eof <- true;
  release_stream stream

let fail_and_close stream error =
  Eta.Effect.scoped
    (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
       ~release:(fun () -> close_stream_unlocked stream)
    |> Eta.Effect.bind (fun () -> Eta.Effect.fail error))

let close_stream stream =
  with_operation stream (close_stream_unlocked stream)

let buffer_too_large stream =
  Decode_error
    {
      provider = stream.provider.name;
      message =
        Printf.sprintf "SSE buffer exceeded %d bytes"
          stream.max_buffer_bytes;
      raw = None;
    }

let record_too_large stream record =
  String.length record > stream.max_buffer_bytes

let parse_sse_record_capped stream record =
  if record_too_large stream record then Stdlib.Error (buffer_too_large stream)
  else Stdlib.Ok (parse_sse_record record)

let trailing_separator_prefix_len buffer =
  let len = Buffer.length buffer in
  let suffix_is value =
    let value_len = String.length value in
    let rec loop index =
      index = value_len
      || (Buffer.nth buffer (len - value_len + index) = value.[index]
         && loop (index + 1))
    in
    len >= value_len && loop 0
  in
  if suffix_is "\r\n\r" then 3
  else if suffix_is "\r\n" then 2
  else if len > 0 then
    match Buffer.nth buffer (len - 1) with '\n' | '\r' -> 1 | _ -> 0
  else 0

let unframed_buffer_too_large stream =
  let len = Buffer.length stream.buffer in
  len - trailing_separator_prefix_len stream.buffer > stream.max_buffer_bytes

let rec drain_sse_records stream acc =
  match find_sse_separator stream with
  | None ->
      stream.scan_pos <- max 0 (Buffer.length stream.buffer - 3);
      Stdlib.Ok acc
  | Some (index, sep_len) ->
      let contents = Buffer.contents stream.buffer in
      let record = String.sub contents 0 index in
      let rest_start = index + sep_len in
      Buffer.clear stream.buffer;
      Buffer.add_substring stream.buffer contents rest_start
        (String.length contents - rest_start);
      stream.scan_pos <- 0;
      if String.trim record = "" then drain_sse_records stream acc
      else
        match parse_sse_record_capped stream record with
        | Stdlib.Ok event -> drain_sse_records stream (event :: acc)
        | Stdlib.Error _ as error -> error

let feed_sse stream chunk =
  let len = String.length chunk in
  let rec loop index acc =
    if index = len then Stdlib.Ok (List.rev acc)
    else (
      Buffer.add_char stream.buffer chunk.[index];
      match drain_sse_records stream acc with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok acc ->
          if unframed_buffer_too_large stream then
            Stdlib.Error (buffer_too_large stream)
          else loop (index + 1) acc)
  in
  loop 0 []

let flush_sse stream =
  let record = String.trim (Buffer.contents stream.buffer) in
  Buffer.clear stream.buffer;
  stream.scan_pos <- 0;
  if record = "" then Stdlib.Ok []
  else Result.map (fun event -> [ event ]) (parse_sse_record_capped stream record)

let decode_sse_records stream records =
  let rec loop acc = function
    | [] -> Eta.Effect.pure (List.rev acc)
    | record :: rest -> (
        match stream.provider.decode_stream_event record with
        | Ok events -> loop (List.rev_append events acc) rest
        | Error error -> fail_and_close stream error)
  in
  loop [] records

let rec read_stream_event_unlocked stream =
  match stream.pending with
  | event :: rest ->
      stream.pending <- rest;
      Eta.Effect.pure (Some event)
  | [] when stream.eof -> Eta.Effect.pure None
  | [] ->
      Eta_http.Body.Stream.read stream.body
      |> Eta.Effect.catch (fun error ->
             fail_and_close stream (Eta_http_error error))
      |> Eta.Effect.bind (function
           | None ->
               stream.eof <- true;
               (match flush_sse stream with
               | Stdlib.Error error -> fail_and_close stream error
               | Stdlib.Ok records ->
                   decode_sse_records stream records
                   |> Eta.Effect.bind (fun events ->
                          stream.pending <- events;
                          release_stream stream
                          |> Eta.Effect.bind (fun () -> read_stream_event_unlocked stream)))
           | Some chunk ->
               (match feed_sse stream (Bytes.to_string chunk) with
               | Stdlib.Error error -> fail_and_close stream error
               | Stdlib.Ok records ->
                   decode_sse_records stream records
                   |> Eta.Effect.bind (fun events ->
                          stream.pending <- events;
                          read_stream_event_unlocked stream)))

let read_stream_event stream =
  with_operation stream (read_stream_event_unlocked stream)

let read_stream_events ?max_events stream =
  Option.iter
    (fun max_events ->
      if max_events < 0 then invalid_arg "Eta_ai.read_stream_events")
    max_events;
  let rec loop remaining acc =
    match remaining with
    | Some 0 ->
        close_stream_unlocked stream |> Eta.Effect.bind (fun () ->
            Eta.Effect.pure (List.rev acc))
    | _ -> (
        read_stream_event_unlocked stream |> Eta.Effect.bind (function
          | None -> Eta.Effect.pure (List.rev acc)
          | Some event ->
              let remaining =
                Option.map (fun value -> value - 1) remaining
              in
              loop remaining (event :: acc)))
  in
  with_operation stream (loop max_events [])
