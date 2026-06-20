type level = Capabilities.log_level =
  | Trace
  | Debug
  | Info
  | Warn
  | Error
  | Fatal

type record = Capabilities.log_record = {
  level : level;
  body : string;
  ts_ms : int;
  attrs : (string * string) list;
  trace_id : string;
  span_id : string;
}

type in_memory = { mutex : Sync_lock.t; mutable records : record list }

let in_memory () = { mutex = Sync_lock.create (); records = [] }

let with_lock t f = Sync_lock.use t.mutex f

let push t r = with_lock t (fun () -> t.records <- r :: t.records)
let dump t = with_lock t (fun () -> List.rev t.records)

let as_capability t : Capabilities.logger =
  object
    method log r = push t r
  end

let noop : Capabilities.logger =
  object
    method log _ = ()
  end

let level_rank = function
  | Trace -> 0
  | Debug -> 1
  | Info -> 2
  | Warn -> 3
  | Error -> 4
  | Fatal -> 5

let level_enabled ~threshold level = level_rank level >= level_rank threshold

let level_upper = function
  | Trace -> "TRACE"
  | Debug -> "DEBUG"
  | Info -> "INFO"
  | Warn -> "WARN"
  | Error -> "ERROR"
  | Fatal -> "FATAL"

let level_lower level = String.lowercase_ascii (level_upper level)

let timestamp_clock ts_ms =
  let day_ms = 86_400_000 in
  let day_offset = ((ts_ms mod day_ms) + day_ms) mod day_ms in
  let hours = day_offset / 3_600_000 in
  let minutes = day_offset mod 3_600_000 / 60_000 in
  let seconds = day_offset mod 60_000 / 1_000 in
  let millis = day_offset mod 1_000 in
  Printf.sprintf "%02d:%02d:%02d.%03d" hours minutes seconds millis

let needs_quote s =
  String.equal s ""
  || String.exists
       (function
         | ' ' | '\t' | '\n' | '\r' | '"' | '=' -> true
         | _ -> false)
       s

let quote_logfmt_value s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (function
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '"' -> Buffer.add_string buffer "\\\""
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | c -> Buffer.add_char buffer c)
    s;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let format_value s = if needs_quote s then quote_logfmt_value s else s

let validate_label caller label =
  let valid =
    (not (String.equal label ""))
    && not
         (String.exists
            (function
              | ' ' | '\t' | '\n' | '\r' | '"' | '=' -> true
              | _ -> false)
            label)
  in
  if not valid then invalid_arg (caller ^ ": invalid logfmt label " ^ label)

let logfmt_field caller (key, value) =
  validate_label caller key;
  key ^ "=" ^ format_value value

let pretty_field (key, value) = format_value key ^ "=" ^ format_value value

let append_trace_fields record fields =
  let fields =
    if String.equal record.trace_id "" then fields
    else ("trace_id", record.trace_id) :: fields
  in
  if String.equal record.span_id "" then fields
  else ("span_id", record.span_id) :: fields

let format_pretty record =
  let fields = append_trace_fields record (List.rev record.attrs) |> List.rev in
  let field_text =
    match fields with
    | [] -> ""
    | fields ->
        " "
        ^ String.concat " "
            (List.map pretty_field fields)
  in
  Printf.sprintf "[%s] %s %s%s" (timestamp_clock record.ts_ms)
    (level_upper record.level) record.body field_text

let format_logfmt record =
  let fields =
    [
      ("timestamp_ms", string_of_int record.ts_ms);
      ("level", level_lower record.level);
      ("msg", record.body);
    ]
    @ record.attrs
    @ List.rev (append_trace_fields record [])
  in
  String.concat " " (List.map (logfmt_field "Logger.format_logfmt") fields)

let json_escape s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\b' -> Buffer.add_string buffer "\\b"
      | '\012' -> Buffer.add_string buffer "\\f"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buffer (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buffer c)
    s;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let json_string_field key value = json_escape key ^ ":" ^ json_escape value

let format_json record =
  let attrs =
    record.attrs
    |> List.map (fun (key, value) -> json_string_field key value)
    |> String.concat ","
  in
  let fields =
    [
      "\"timestamp_ms\":" ^ string_of_int record.ts_ms;
      json_string_field "level" (level_lower record.level);
      json_string_field "msg" record.body;
      "\"attrs\":{" ^ attrs ^ "}";
    ]
  in
  let fields =
    if String.equal record.trace_id "" then fields
    else fields @ [ json_string_field "trace_id" record.trace_id ]
  in
  let fields =
    if String.equal record.span_id "" then fields
    else fields @ [ json_string_field "span_id" record.span_id ]
  in
  "{" ^ String.concat "," fields ^ "}"

let with_min_level threshold logger : Capabilities.logger =
  object
    method log record =
      if level_enabled ~threshold record.level then logger#log record
  end

let write_channel channel line =
  output_string channel line;
  output_char channel '\n';
  flush channel

let default_stdout line = write_channel stdout line
let default_stderr line = write_channel stderr line

let routed_console ?(stdout = default_stdout) ?(stderr = default_stderr)
    ?min_level format =
  let lock = Sync_lock.create () in
  object
    method log record =
      let enabled =
        match min_level with
        | None -> true
        | Some threshold -> level_enabled ~threshold record.level
      in
      if enabled then
        let line = format record in
        let write =
          match record.level with Error | Fatal -> stderr | _ -> stdout
        in
        Sync_lock.use lock (fun () -> write line)
  end

let console_pretty ?stdout ?stderr ?min_level () =
  routed_console ?stdout ?stderr ?min_level format_pretty

let console_logfmt ?stdout ?stderr ?min_level () =
  routed_console ?stdout ?stderr ?min_level format_logfmt

let console_json ?stdout ?stderr ?min_level () =
  routed_console ?stdout ?stderr ?min_level format_json
