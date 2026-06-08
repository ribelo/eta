open Eta

module Body = Http.Body.Stream
module Http_error = Http.Error
module Json = Yojson.Safe

type provider = Openai | Anthropic | Openrouter

type sse_event = {
  event : string option;
  data : string;
}

type ai_event =
  | Text_delta of string
  | Tool_args_delta of int * string
  | Done
  | Ai_error of string
  | Other of string

type parse_result = {
  events : ai_event list;
  max_buffer : int;
}

type parser_state = {
  mutable buffer : string;
  mutable max_buffer : int;
}

let provider_name = function
  | Openai -> "openai"
  | Anthropic -> "anthropic"
  | Openrouter -> "openrouter"

let starts_with ~prefix s =
  let prefix_len = String.length prefix in
  String.length s >= prefix_len && String.sub s 0 prefix_len = prefix

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
               if field = "event" then event := Some value
               else if field = "data" then data := value :: !data);
  { event = !event; data = String.concat "\n" (List.rev !data) }

let find_sse_separator s =
  let len = String.length s in
  let rec loop index =
    if index >= len then None
    else if index + 1 < len && s.[index] = '\n' && s.[index + 1] = '\n' then
      Some (index, 2)
    else if
      index + 3 < len && s.[index] = '\r' && s.[index + 1] = '\n'
      && s.[index + 2] = '\r' && s.[index + 3] = '\n'
    then Some (index, 4)
    else loop (index + 1)
  in
  loop 0

let feed_sse state chunk =
  state.buffer <- state.buffer ^ chunk;
  state.max_buffer <- max state.max_buffer (String.length state.buffer);
  let rec drain acc =
    match find_sse_separator state.buffer with
    | None -> List.rev acc
    | Some (index, sep_len) ->
        let record = String.sub state.buffer 0 index in
        let rest_start = index + sep_len in
        state.buffer <-
          String.sub state.buffer rest_start
            (String.length state.buffer - rest_start);
        if String.trim record = "" then drain acc
        else drain (parse_sse_record record :: acc)
  in
  drain []

let flush_sse state =
  let record = String.trim state.buffer in
  state.buffer <- "";
  if record = "" then [] else [ parse_sse_record record ]

let member name = function
  | `Assoc fields -> (
      match List.assoc_opt name fields with
      | Some value -> value
      | None -> `Null)
  | _ -> `Null

let as_string = function
  | `String value -> Some value
  | _ -> None

let as_int = function
  | `Int value -> Some value
  | _ -> None

let as_list = function
  | `List values -> values
  | _ -> []

let is_null = function
  | `Null -> true
  | _ -> false

let option_default default = function
  | Some value -> value
  | None -> default

let json_message json =
  match member "error" json with
  | `Assoc _ as error ->
      option_default (Json.to_string error) (as_string (member "message" error))
  | _ -> option_default (Json.to_string json) (as_string (member "message" json))

let parse_json provider data =
  try Ok (Json.from_string data)
  with exn ->
    Error
      (Printf.sprintf "%s JSON parse failed: %s" (provider_name provider)
         (Printexc.to_string exn))

let decode_openai_json json =
  if not (is_null (member "error" json)) then [ Ai_error (json_message json) ]
  else
    let decode_choice choice =
      let delta = member "delta" choice in
      let text_events =
        match as_string (member "content" delta) with
        | Some text when text <> "" -> [ Text_delta text ]
        | _ -> []
      in
      let tool_events =
        member "tool_calls" delta |> as_list
        |> List.filter_map (fun call ->
               let index = option_default 0 (as_int (member "index" call)) in
               let fn = member "function" call in
               match as_string (member "arguments" fn) with
               | Some args -> Some (Tool_args_delta (index, args))
               | None -> None)
      in
      text_events @ tool_events
    in
    member "choices" json |> as_list |> List.concat_map decode_choice

let decode_openai sse =
  let data = String.trim sse.data in
  if data = "[DONE]" then Ok [ Done ]
  else
    match parse_json Openai data with
    | Error _ as error -> error
    | Ok json ->
        if sse.event = Some "error" then Ok [ Ai_error (json_message json) ]
        else Ok (decode_openai_json json)

let decode_anthropic sse =
  let data = String.trim sse.data in
  match parse_json Anthropic data with
  | Error _ as error -> error
  | Ok json -> (
      match sse.event with
      | Some "error" -> Ok [ Ai_error (json_message json) ]
      | Some "message_stop" -> Ok [ Done ]
      | Some "content_block_delta" -> (
          let delta = member "delta" json in
          match as_string (member "type" delta) with
          | Some "text_delta" -> (
              match as_string (member "text" delta) with
              | Some text -> Ok [ Text_delta text ]
              | None -> Ok [])
          | Some "input_json_delta" -> (
              let index = option_default 0 (as_int (member "index" json)) in
              match as_string (member "partial_json" delta) with
              | Some partial -> Ok [ Tool_args_delta (index, partial) ]
              | None -> Ok [])
          | _ -> Ok [ Other "anthropic.content_block_delta" ])
      | _ -> (
          match as_string (member "type" json) with
          | Some "error" -> Ok [ Ai_error (json_message json) ]
          | Some event_type -> Ok [ Other ("anthropic." ^ event_type) ]
          | None -> Ok []))

let decode_openrouter sse =
  let data = String.trim sse.data in
  if data = "[DONE]" then Ok [ Done ]
  else
    match parse_json Openrouter data with
    | Error _ as error -> error
    | Ok json ->
        if not (is_null (member "error" json)) then
          Ok [ Ai_error (json_message json) ]
        else Ok (decode_openai_json json)

let decode_sse provider sse =
  match provider with
  | Openai -> decode_openai sse
  | Anthropic -> decode_anthropic sse
  | Openrouter -> decode_openrouter sse

let decode_many provider records =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | record :: rest -> (
        match decode_sse provider record with
        | Error _ as error -> error
        | Ok events -> loop (List.rev_append events acc) rest)
  in
  loop [] records

let read_body body =
  Body.read body
  |> Effect.catch (fun error ->
         Effect.fail ("body read failed: " ^ Http_error.to_string error))

let discard_body body =
  Body.discard body
  |> Effect.catch (fun error ->
         Effect.fail ("body discard failed: " ^ Http_error.to_string error))

let first_n n values =
  let rec loop remaining acc = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | value :: rest -> loop (remaining - 1) (value :: acc) rest
  in
  loop n [] values

let parse_body ?max_events provider body =
  let state = { buffer = ""; max_buffer = 0 } in
  let maybe_stop acc =
    match max_events with
    | Some max when List.length acc >= max ->
        Some { events = first_n max acc; max_buffer = state.max_buffer }
    | _ -> None
  in
  let rec loop acc =
    match maybe_stop acc with
    | Some result -> Effect.pure result
    | None -> (
        read_body body
        |> Effect.bind (function
             | None -> (
                 match decode_many provider (flush_sse state) with
                 | Error error -> Effect.fail error
                 | Ok events ->
                     let acc = acc @ events in
                     Effect.pure { events = acc; max_buffer = state.max_buffer })
             | Some chunk -> (
                 let records = feed_sse state (Bytes.to_string chunk) in
                 match decode_many provider records with
                 | Error error -> Effect.fail error
                 | Ok events -> loop (acc @ events))))
  in
  Effect.scoped
    (Effect.acquire_release ~acquire:Effect.unit
       ~release:(fun () -> discard_body body)
    |> Effect.bind (fun () -> loop []))

let repo_probe_dir = "scratch/eta_ai_v1/probes/streaming_sse"
let fixture name = Filename.concat repo_probe_dir (Filename.concat "fixtures" name)

let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let chunk_string value =
  let sizes = [| 1; 7; 2; 31; 5; 13; 3; 89 |] in
  let rec loop index size_index acc =
    if index >= String.length value then List.rev acc
    else
      let size = sizes.(size_index mod Array.length sizes) in
      let len = min size (String.length value - index) in
      let chunk = Bytes.of_string (String.sub value index len) in
      loop (index + len) (size_index + 1) (chunk :: acc)
  in
  loop 0 0 []

let body_of_string ?release value =
  match release with
  | Some release -> Body.of_bytes ~release (chunk_string value)
  | None -> Body.of_bytes (chunk_string value)

let run_effect rt label eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      failwith
        (Printf.sprintf "%s failed: %s" label
           (Format.asprintf "%a" (Cause.pp Format.pp_print_string) cause))

let parse_fixture rt provider filename =
  let body = body_of_string (read_file (fixture filename)) in
  run_effect rt filename (parse_body provider body)

let text_of events =
  let buffer = Buffer.create 32 in
  List.iter
    (function
      | Text_delta text -> Buffer.add_string buffer text
      | Tool_args_delta _ | Done | Ai_error _ | Other _ -> ())
    events;
  Buffer.contents buffer

let tool_args index events =
  let buffer = Buffer.create 32 in
  List.iter
    (function
      | Tool_args_delta (actual, text) when actual = index ->
          Buffer.add_string buffer text
      | Text_delta _ | Tool_args_delta _ | Done | Ai_error _ | Other _ -> ())
    events;
  Buffer.contents buffer

let errors_of events =
  List.filter_map
    (function
      | Ai_error message -> Some message
      | Text_delta _ | Tool_args_delta _ | Done | Other _ -> None)
    events

let has_done events =
  List.exists
    (function
      | Done -> true
      | Text_delta _ | Tool_args_delta _ | Ai_error _ | Other _ -> false)
    events

let check name condition =
  if condition then Printf.printf "ok %s\n" name
  else failwith ("check failed: " ^ name)

let rss_kib () =
  try
    let input = open_in "/proc/self/status" in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () ->
        let rec loop () =
          match input_line input with
          | line when starts_with ~prefix:"VmRSS:" line -> (
              try Scanf.sscanf line "VmRSS: %d kB" (fun value -> value)
              with _ -> -1)
          | _ -> loop ()
          | exception End_of_file -> -1
        in
        loop ())
  with _ -> -1

let memory_probe rt fixture_text =
  let before = rss_kib () in
  let max_buffer = ref 0 in
  for _ = 1 to 1000 do
    let body = body_of_string fixture_text in
    let result = run_effect rt "memory" (parse_body Openai body) in
    max_buffer := max !max_buffer result.max_buffer
  done;
  Gc.full_major ();
  let after = rss_kib () in
  let delta = if before >= 0 && after >= 0 then after - before else -1 in
  (!max_buffer, before, after, delta)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in

  let openai = parse_fixture rt Openai "openai_tool.sse" in
  check "openai text deltas" (text_of openai.events = "Hello");
  check "openai tool args" (tool_args 0 openai.events = "{\"location\":\"SF\"}");
  check "openai done" (has_done openai.events);
  check "openai bounded parser buffer" (openai.max_buffer < 4096);

  let anthropic = parse_fixture rt Anthropic "anthropic_tool.sse" in
  check "anthropic text deltas" (text_of anthropic.events = "Hello");
  check "anthropic tool args"
    (tool_args 1 anthropic.events = "{\"location\":\"SF\"}");
  check "anthropic done" (has_done anthropic.events);
  check "anthropic bounded parser buffer" (anthropic.max_buffer < 4096);

  let openai_error = parse_fixture rt Openai "openai_error.sse" in
  check "openai error is typed event"
    (errors_of openai_error.events = [ "Rate limit exceeded" ]);

  let anthropic_error = parse_fixture rt Anthropic "anthropic_error.sse" in
  check "anthropic error is typed event"
    (errors_of anthropic_error.events = [ "Overloaded" ]);

  let openrouter = parse_fixture rt Openrouter "openrouter_error.sse" in
  check "openrouter text before error" (text_of openrouter.events = "partial");
  check "openrouter error is typed event"
    (errors_of openrouter.events = [ "Provider disconnected" ]);

  let released = ref 0 in
  let body =
    body_of_string
      ~release:(fun () ->
        incr released;
        Effect.unit)
      (read_file (fixture "openai_tool.sse"))
  in
  let stopped = run_effect rt "cancel" (parse_body ~max_events:1 Openai body) in
  check "early stop kept first event" (List.length stopped.events = 1);
  check "early stop released body" (!released = 1);
  ignore (run_effect rt "discard again" (discard_body body));
  check "release idempotent" (!released = 1);

  let fixture_text = read_file (fixture "openai_tool.sse") in
  let max_buffer, rss_before, rss_after, rss_delta = memory_probe rt fixture_text in
  check "memory probe parser buffer" (max_buffer < 4096);
  check "memory probe rss sample" (rss_delta < 32768 || rss_delta = -1);

  Printf.printf "sse_probe=ok\n";
  Printf.printf "openai_events=%d openai_max_buffer=%d\n"
    (List.length openai.events) openai.max_buffer;
  Printf.printf "anthropic_events=%d anthropic_max_buffer=%d\n"
    (List.length anthropic.events) anthropic.max_buffer;
  Printf.printf "openrouter_events=%d openrouter_max_buffer=%d\n"
    (List.length openrouter.events) openrouter.max_buffer;
  Printf.printf "early_stop_release_count=%d\n" !released;
  Printf.printf "rss_before_kib=%d rss_after_kib=%d rss_delta_kib=%d max_buffer=%d\n"
    rss_before rss_after rss_delta max_buffer
