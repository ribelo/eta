module E = Eta.Effect

let ( let* ) = Result.bind

type replayability = Replayable | One_shot
type reader = unit -> bytes option

type source = {
  length : int64 option;
  replayability : replayability;
  open_reader : unit -> reader;
}

type data = Buffered of bytes | Pull of source

type part =
  | Text of {
      name : string;
      value : string;
    }
  | File of {
      name : string;
      filename : string;
      content_type : string;
      data : data;
    }

type error =
  | Empty
  | Invalid_disposition of string
  | Invalid_header of string
  | Length_overflow
  | Impossible_shape of string

type t = {
  boundary : string;
  content_length : int64 option;
  body : Request.body;
}

let boundary_prefix = "eta-http-"

let error_message = function
  | Empty -> "multipart must contain at least one part"
  | Invalid_disposition component ->
      component ^ " contains an invalid multipart character"
  | Invalid_header component ->
      component ^ " contains an invalid multipart header character"
  | Length_overflow -> "multipart content length overflows the supported range"
  | Impossible_shape message -> "invalid multipart shape: " ^ message

let invalid_disposition component value =
  if
    String.contains value '\r' || String.contains value '\n'
    || String.contains value '"'
  then Error (Invalid_disposition component)
  else Ok ()

let invalid_header component value =
  if String.contains value '\r' || String.contains value '\n' then
    Error (Invalid_header component)
  else Ok ()

let validate_source source =
  match source.length with
  | Some length when Int64.compare length 0L < 0 ->
      Error (Impossible_shape "a source length must not be negative")
  | None | Some _ -> Ok ()

let validate_part = function
  | Text { name; _ } -> invalid_disposition "field name" name
  | File { name; filename; content_type; data } ->
      let* () = invalid_disposition "file field" name in
      let* () = invalid_disposition "filename" filename in
      let* () = invalid_header "content type" content_type in
      (match data with Buffered _ -> Ok () | Pull source -> validate_source source)

let validate = function
  | [] -> Error Empty
  | parts ->
      let rec loop = function
        | [] -> Ok ()
        | part :: rest ->
            let* () = validate_part part in
            loop rest
      in
      loop parts

let contains_string value needle =
  let value_length = String.length value in
  let needle_length = String.length needle in
  let rec loop index =
    if needle_length = 0 then true
    else if index + needle_length > value_length then false
    else if String.sub value index needle_length = needle then true
    else loop (index + 1)
  in
  loop 0

let contains_bytes value needle =
  let value_length = Bytes.length value in
  let needle_length = String.length needle in
  let rec equal_at offset index =
    index = needle_length
    ||
    (Bytes.get value (offset + index) = String.get needle index
    && equal_at offset (index + 1))
  in
  let rec loop index =
    if needle_length = 0 then true
    else if index + needle_length > value_length then false
    else if equal_at index 0 then true
    else loop (index + 1)
  in
  loop 0

let part_static_strings = function
  | Text { name; value } -> [ name; value ]
  | File { name; filename; content_type; _ } ->
      [ name; filename; content_type ]

let boundary_collides parts boundary =
  List.exists
    (fun part ->
      List.exists
        (fun value -> contains_string value boundary)
        (part_static_strings part)
      ||
      match part with
      | File { data = Buffered bytes; _ } -> contains_bytes bytes boundary
      | Text _ | File { data = Pull _; _ } -> false)
    parts

let add_seed_string buffer value =
  Buffer.add_string buffer (string_of_int (String.length value));
  Buffer.add_char buffer ':';
  Buffer.add_string buffer value

let add_seed_bytes buffer value =
  Buffer.add_string buffer (string_of_int (Bytes.length value));
  Buffer.add_char buffer ':';
  Buffer.add_bytes buffer value

let buffered_seed parts =
  let buffer = Buffer.create 256 in
  (match parts with
  | Text { name; value } :: _ ->
      add_seed_string buffer name;
      add_seed_string buffer value
  | File { data = Buffered bytes; _ } :: _ -> add_seed_bytes buffer bytes
  | [] | File { data = Pull _; _ } :: _ -> assert false);
  Buffer.contents buffer

let deterministic_boundary parts =
  let digest = Digest.to_hex (Digest.string (buffered_seed parts)) in
  let rec choose suffix =
    let boundary =
      boundary_prefix ^ digest
      ^ if suffix = 0 then "" else "-" ^ string_of_int suffix
    in
    if boundary_collides parts boundary then choose (suffix + 1) else boundary
  in
  choose 0

let boundary_counter = Atomic.make 0

let random_token () =
  let state = Random.State.make_self_init () in
  let bytes = Bytes.create 32 in
  for index = 0 to Bytes.length bytes - 1 do
    Bytes.set bytes index (Char.chr (Random.State.int state 256))
  done;
  let counter = Atomic.fetch_and_add boundary_counter 1 in
  Digest.to_hex
    (Digest.string (Bytes.unsafe_to_string bytes ^ ":" ^ string_of_int counter))

let fresh_boundary parts =
  let rec choose () =
    let boundary = boundary_prefix ^ random_token () in
    if boundary_collides parts boundary then choose () else boundary
  in
  choose ()

let part_header boundary = function
  | Text { name; _ } ->
      Bytes.of_string
        ("--" ^ boundary
       ^ "\r\nContent-Disposition: form-data; name=\"" ^ name ^ "\"\r\n\r\n")
  | File { name; filename; content_type; _ } ->
      Bytes.of_string
        ("--" ^ boundary
       ^ "\r\nContent-Disposition: form-data; name=\"" ^ name
       ^ "\"; filename=\"" ^ filename ^ "\"\r\nContent-Type: " ^ content_type
       ^ "\r\n\r\n")

let part_static_chunks boundary = function
  | Text { value; _ } ->
      [ Bytes.of_string value; Bytes.of_string "\r\n" ]
  | File { data = Buffered bytes; _ } ->
      [ bytes; Bytes.of_string "\r\n" ]
  | File { data = Pull _; _ } -> []

let closing boundary = Bytes.of_string ("--" ^ boundary ^ "--\r\n")

let checked_add left right =
  if Int64.compare right 0L < 0 then None
  else if Int64.compare left (Int64.sub Int64.max_int right) > 0 then None
  else Some (Int64.add left right)

let checked_add_bytes total bytes =
  checked_add total (Int64.of_int (Bytes.length bytes))

let content_length boundary parts =
  let rec add_part total = function
    | [] -> checked_add_bytes total (closing boundary)
    | part :: rest ->
        Option.bind
          (checked_add_bytes total (part_header boundary part))
          (fun total ->
            let content_length =
              match part with
              | Text { value; _ } -> Some (Int64.of_int (String.length value))
              | File { data = Buffered bytes; _ } ->
                  Some (Int64.of_int (Bytes.length bytes))
              | File { data = Pull { length; _ }; _ } -> length
            in
            Option.bind content_length (fun length ->
                Option.bind (checked_add total length) (fun total ->
                    Option.bind (checked_add total 2L) (fun total ->
                        add_part total rest))))
  in
  add_part 0L parts

let http_error codec message =
  Error.make ~method_:"*" ~uri:"*"
    (Error.Decode_error { codec; message })

let source_error exn =
  http_error "multipart-source" (Printexc.to_string exn)

let collision_error () =
  http_error "multipart-boundary" "source contains the multipart boundary delimiter"

let source_length_error message =
  http_error "multipart-source-length" message

let find_bytes value needle =
  let value_length = Bytes.length value in
  let needle_length = Bytes.length needle in
  let rec equal_at offset index =
    index = needle_length
    ||
    (Bytes.get value (offset + index) = Bytes.get needle index
    && equal_at offset (index + 1))
  in
  let rec loop index =
    if index + needle_length > value_length then None
    else if equal_at index 0 then Some index
    else loop (index + 1)
  in
  loop 0

let append_bytes left right =
  let left_length = Bytes.length left in
  let right_length = Bytes.length right in
  let result = Bytes.create (left_length + right_length) in
  Bytes.blit left 0 result 0 left_length;
  Bytes.blit right 0 result left_length right_length;
  result

type source_state = {
  source : source;
  mutable reader : reader option;
  mutable pending : bytes;
  mutable context_length : int;
  mutable remaining : int64 option;
  mutable collided : bool;
}

type stream_item = Static of bytes | Source of source_state

let without_context state bytes =
  let drop = min state.context_length (Bytes.length bytes) in
  state.context_length <- state.context_length - drop;
  Bytes.sub bytes drop (Bytes.length bytes - drop)

let source_chunk delimiter state =
  let rec read () =
    if state.collided then E.fail (collision_error ())
    else
      let reader =
        match state.reader with
        | Some reader -> Ok reader
        | None -> (
            match state.source.open_reader () with
            | reader ->
                state.reader <- Some reader;
                Ok reader
            | exception exn -> Error exn)
      in
      match reader with
      | Error exn -> E.fail (source_error exn)
      | Ok reader -> (
          match reader () with
          | exception exn -> E.fail (source_error exn)
          | Some chunk when Bytes.length chunk = 0 -> read ()
          | None ->
              (match state.remaining with
              | Some remaining when Int64.compare remaining 0L <> 0 ->
                  E.fail
                    (source_length_error
                       "source ended before its declared length")
              | None | Some _ ->
                  let pending = without_context state state.pending in
                  state.pending <- Bytes.empty;
                  E.pure (`End pending))
          | Some chunk -> (
              let chunk_length = Int64.of_int (Bytes.length chunk) in
              match state.remaining with
              | Some remaining when Int64.compare chunk_length remaining > 0 ->
                  E.fail
                    (source_length_error
                       "source chunk exceeds its declared length")
              | remaining ->
                  state.remaining <-
                    Option.map
                      (fun remaining -> Int64.sub remaining chunk_length)
                      remaining;
              let combined = append_bytes state.pending chunk in
              match find_bytes combined delimiter with
              | Some offset ->
                  state.collided <- true;
                  state.pending <- Bytes.empty;
                  let safe = without_context state (Bytes.sub combined 0 offset) in
                  if Bytes.length safe = 0 then E.fail (collision_error ())
                  else E.pure (`Chunk safe)
              | None ->
                  let keep = min (Bytes.length combined) (Bytes.length delimiter - 1) in
                  let emit_length = Bytes.length combined - keep in
                  state.pending <- Bytes.sub combined emit_length keep;
                  let emitted =
                    without_context state (Bytes.sub combined 0 emit_length)
                  in
                  if Bytes.length emitted = 0 then read ()
                  else E.pure (`Chunk emitted)))
  in
  read ()

let make_stream boundary items =
  let delimiter = Bytes.of_string ("\r\n--" ^ boundary) in
  let items = ref items in
  let rec read () =
    match !items with
    | [] -> E.pure Stream.End
    | Static bytes :: rest ->
        items := rest;
        E.pure (Stream.Chunk bytes)
    | Source state :: rest ->
        source_chunk delimiter state
        |> E.bind (function
             | `Chunk bytes -> E.pure (Stream.Chunk bytes)
             | `End pending ->
                 items := Static pending :: Static (Bytes.of_string "\r\n") :: rest;
                 read ())
  in
  Stream.of_reader read

let stream_items boundary parts =
  List.concat_map
    (fun part ->
      let header = Static (part_header boundary part) in
      match part with
      | Text _ | File { data = Buffered _; _ } ->
          header
          :: List.map (fun bytes -> Static bytes) (part_static_chunks boundary part)
      | File { data = Pull source; _ } ->
          [
            header;
            Source
              {
                source;
                reader = None;
                pending = Bytes.of_string "\r\n";
                context_length = 2;
                remaining = source.length;
                collided = false;
              };
          ])
    parts
  @ [ Static (closing boundary) ]

let all_replayable parts =
  List.for_all
    (function
      | Text _ | File { data = Buffered _; _ } -> true
      | File { data = Pull { replayability = Replayable; _ }; _ } -> true
      | File { data = Pull { replayability = One_shot; _ }; _ } -> false)
    parts

let has_pull parts =
  List.exists
    (function File { data = Pull _; _ } -> true | Text _ | File _ -> false)
    parts

let fixed_chunks boundary parts =
  List.concat_map
    (fun part ->
      part_header boundary part :: part_static_chunks boundary part)
    parts
  @ [ closing boundary ]

let make parts =
  let* () = validate parts in
  if not (has_pull parts) then
    let boundary = deterministic_boundary parts in
    let body = Request.Fixed (fixed_chunks boundary parts) in
    let content_length =
      match content_length boundary parts with
      | Some length -> length
      | None -> assert false
    in
    Ok { boundary; content_length = Some content_length; body }
  else
    let boundary = fresh_boundary parts in
    match content_length boundary parts with
    | None
      when List.for_all
             (function
               | Text _ | File { data = Buffered _; _ } -> true
               | File { data = Pull { length = None; _ }; _ } -> false
               | File { data = Pull { length = Some _; _ }; _ } -> true)
             parts ->
        Error Length_overflow
    | content_length ->
        let* () =
          match content_length with
          | Some length when Int64.compare length (Int64.of_int max_int) > 0 ->
              Error Length_overflow
          | None | Some _ -> Ok ()
        in
        let make_body () = make_stream boundary (stream_items boundary parts) in
        let body =
          if all_replayable parts then
            let length = Option.map Int64.to_int content_length in
            Request.Rewindable_stream { length; make = make_body }
          else
            match content_length with
            | Some length ->
                Request.One_shot_stream
                  { length = Int64.to_int length; stream = make_body () }
            | None -> Request.Stream (make_body ())
        in
        Ok { boundary; content_length; body }
