type t : immutable_data = Capabilities.trace_context = {
  trace_id : string;
  span_id : string;
  trace_flags : int;
  trace_state : (string * string) list;
  baggage : (string * string) list;
}

let sampled t = t.trace_flags land 1 = 1

let is_hex len s =
  String.length s = len
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       s

let not_zero s = String.exists (( <> ) '0') s

let valid_trace_id s = is_hex 32 s && not_zero s
let valid_span_id s = is_hex 16 s && not_zero s

let make ?(trace_flags = 1) ?(trace_state = []) ?(baggage = []) ~trace_id
    ~span_id () =
  if valid_trace_id trace_id && valid_span_id span_id then
    Some
      {
        trace_id;
        span_id;
        trace_flags = trace_flags land 255;
        trace_state;
        baggage;
      }
  else None

let find_header name headers =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (k, v) ->
      if String.lowercase_ascii k = name then Some (String.trim v) else None)
    headers

let parse_flags s =
  if is_hex 2 s then Some (int_of_string ("0x" ^ s)) else None

let valid_version s = is_hex 2 s && s <> "ff"

let parse_trace_state s =
  if String.trim s = "" then []
  else
    s |> String.split_on_char ','
    |> List.filter_map (fun item ->
           match String.split_on_char '=' item with
           | [ k; v ] ->
               let k = String.trim k and v = String.trim v in
               if k = "" || v = "" then None else Some (k, v)
           | _ -> None)

let parse_baggage s =
  if String.trim s = "" then []
  else
    s |> String.split_on_char ','
    |> List.filter_map (fun item ->
           let item =
             match String.split_on_char ';' item with
             | head :: _ -> head
             | [] -> item
           in
           match String.split_on_char '=' item with
           | [ k; v ] ->
               let k = String.trim k and v = String.trim v in
               if k = "" then None else Some (k, v)
           | _ -> None)

let extract headers =
  let make_from_traceparent ~trace_id ~span_id ~trace_flags =
    let trace_state =
      Option.value
        (Option.map parse_trace_state (find_header "tracestate" headers))
        ~default:[]
    in
    let baggage =
      Option.value (Option.map parse_baggage (find_header "baggage" headers))
        ~default:[]
    in
    make ~trace_id ~span_id ~trace_flags ~trace_state ~baggage ()
  in
  match find_header "traceparent" headers with
  | None -> None
  | Some traceparent -> (
      match String.split_on_char '-' traceparent with
      | [ "00"; trace_id; span_id; flags ] -> (
          match parse_flags flags with
          | None -> None
          | Some trace_flags ->
              make_from_traceparent ~trace_id ~span_id ~trace_flags)
      | version :: trace_id :: span_id :: flags :: _
        when valid_version version && version <> "00" -> (
          match parse_flags flags with
          | None -> None
          | Some trace_flags ->
              (* W3C Trace Context 3.2.4 requires higher versions to parse the
                 v00 prefix fields when valid, ignore unknown trailing fields,
                 and carry only the sampled bit this version understands. *)
              make_from_traceparent ~trace_id ~span_id
                ~trace_flags:(trace_flags land 1))
      | _ -> None)

let render_pairs xs =
  String.concat "," (List.map (fun (k, v) -> k ^ "=" ^ v) xs)

let inject t =
  let traceparent =
    Printf.sprintf "00-%s-%s-%02x" t.trace_id t.span_id
      (t.trace_flags land 255)
  in
  let headers = [ ("traceparent", traceparent) ] in
  let headers =
    match t.trace_state with
    | [] -> headers
    | xs -> headers @ [ ("tracestate", render_pairs xs) ]
  in
  match t.baggage with
  | [] -> headers
  | xs -> headers @ [ ("baggage", render_pairs xs) ]
