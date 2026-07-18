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

let with_operation stream eff =
  if not (Atomic.compare_and_set stream.active false true) then
    Eta.Effect.fail (concurrent_use stream)
  else (
    eff
    |> Eta.Effect.finally
         (Eta.Effect.sync (fun () -> Atomic.set stream.active false)))

let field_is record start finish literal =
  let literal_len = String.length literal in
  let len = finish - start in
  len = literal_len
  &&
  let rec loop index =
    index = literal_len
    || (record.[start + index] = literal.[index] && loop (index + 1))
  in
  loop 0

let parse_sse_record_slice record record_start record_finish =
  let event = ref None in
  let data = Buffer.create 128 in
  let has_data = ref false in
  let first_data = ref true in
  let handle_line start finish =
    let finish =
      if finish > start && record.[finish - 1] = '\r' then finish - 1
      else finish
    in
    if finish > start && record.[start] <> ':' then
      match String.index_from_opt record start ':' with
      | None -> ()
      | Some colon when colon < finish ->
          let value_start =
            let after_colon = colon + 1 in
            if after_colon < finish && record.[after_colon] = ' ' then
              after_colon + 1
            else after_colon
          in
          if field_is record start colon "event" then
            event := Some (String.sub record value_start (finish - value_start))
          else if field_is record start colon "data" then begin
            has_data := true;
            if !first_data then first_data := false
            else Buffer.add_char data '\n';
            Buffer.add_substring data record value_start (finish - value_start)
          end
      | Some _ -> ()
  in
  let len = record_finish in
  let rec loop line_start index =
    if index = len then handle_line line_start index
    else if record.[index] = '\n' then (
      handle_line line_start index;
      loop (index + 1) (index + 1))
    else loop line_start (index + 1)
  in
  loop record_start record_start;
  let data = Buffer.contents data in
  let rec whitespace_only index =
    index >= String.length data
    ||
    match data.[index] with
    | ' ' | '\t' | '\r' | '\n' -> whitespace_only (index + 1)
    | _ -> false
  in
  if !has_data && not (whitespace_only 0) then Some { event = !event; data }
  else None

let blank_record record start finish =
  let rec loop index =
    index >= finish
    ||
    match record.[index] with
    | ' ' | '\t' | '\r' | '\n' -> loop (index + 1)
    | _ -> false
  in
  loop start

let release_stream stream =
  if stream.released then Eta.Effect.unit
  else (
    stream.released <- true;
    Eta_http.Body.Stream.discard stream.body
    |> Eta.Effect.bind_error (fun error -> Eta.Effect.fail (Eta_http_error error)))

let close_stream_unlocked stream =
  stream.pending <- [];
  Buffer.clear stream.buffer;
  stream.scan_pos <- 0;
  stream.eof <- true;
  release_stream stream

let fail_and_close stream error =
  Eta.Effect.with_scope
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

let parse_sse_record_slice_capped stream record start finish =
  if finish - start > stream.max_buffer_bytes then
    Stdlib.Error (buffer_too_large stream)
  else Stdlib.Ok (parse_sse_record_slice record start finish)

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

let find_sse_separator_in_string s start =
  let len = String.length s in
  let rec loop index =
    if index >= len then None
    else if
      index + 1 < len && s.[index] = '\n' && s.[index + 1] = '\n'
    then Some (index, 2)
    else if
      index + 3 < len && s.[index] = '\r' && s.[index + 1] = '\n'
      && s.[index + 2] = '\r' && s.[index + 3] = '\n'
    then Some (index, 4)
    else loop (index + 1)
  in
  loop start

let drain_sse_records stream acc =
  let contents = Buffer.contents stream.buffer in
  let len = String.length contents in
  let rec loop record_start scan_start acc =
    match find_sse_separator_in_string contents scan_start with
    | None ->
        Buffer.clear stream.buffer;
        Buffer.add_substring stream.buffer contents record_start
          (len - record_start);
        stream.scan_pos <- max 0 (Buffer.length stream.buffer - 3);
        Stdlib.Ok acc
    | Some (index, sep_len) ->
        let next_start = index + sep_len in
        if blank_record contents record_start index then loop next_start next_start acc
        else
          match parse_sse_record_slice_capped stream contents record_start index with
          | Stdlib.Ok None -> loop next_start next_start acc
          | Stdlib.Ok (Some event) -> loop next_start next_start (event :: acc)
          | Stdlib.Error _ as error -> error
  in
  loop 0 stream.scan_pos acc

let feed_sse stream chunk =
  Buffer.add_string stream.buffer chunk;
  match drain_sse_records stream [] with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok events ->
      if unframed_buffer_too_large stream then
        Stdlib.Error (buffer_too_large stream)
      else Stdlib.Ok (List.rev events)

let flush_sse stream =
  let record = Buffer.contents stream.buffer in
  let record_start, record_stop = Eta.String_helpers.trim_bounds record in
  Buffer.clear stream.buffer;
  stream.scan_pos <- 0;
  if record_start = record_stop then Stdlib.Ok []
  else
    Result.map
      (function None -> [] | Some event -> [ event ])
      (parse_sse_record_slice_capped stream record record_start record_stop)

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
      |> Eta.Effect.bind_error (fun error ->
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
               (match feed_sse stream (Bytes.unsafe_to_string chunk) with
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
