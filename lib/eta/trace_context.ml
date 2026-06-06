type t = Capabilities.trace_context = {
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

let equal_header_name = String_helpers.trim_equal_trimmed_ascii_ci

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
  List.find_map
    (fun (k, v) -> if equal_header_name name k then Some v else None)
    headers

let parse_flags s =
  if is_hex 2 s then Some (int_of_string ("0x" ^ s)) else None

let valid_version s = is_hex 2 s && s <> "ff"

let trimmed_sub s start stop =
  let left = ref start in
  let right = ref stop in
  while !left < !right && String_helpers.is_trim_space (String.unsafe_get s !left) do
    incr left
  done;
  while !right > !left && String_helpers.is_trim_space (String.unsafe_get s (!right - 1)) do
    decr right
  done;
  String.sub s !left (!right - !left)

let find_char_between s start stop needle =
  let pos = ref start in
  let found = ref (-1) in
  while !found < 0 && !pos < stop do
    if Char.equal (String.unsafe_get s !pos) needle then found := !pos;
    incr pos
  done;
  !found

let has_char_between s start stop needle =
  let pos = ref start in
  let found = ref false in
  while (not !found) && !pos < stop do
    found := Char.equal (String.unsafe_get s !pos) needle;
    incr pos
  done;
  !found

let parse_comma_pairs ?comment_char ~allow_empty_value s =
  let len = String.length s in
  let rec loop item_start acc pos =
    if pos > len then List.rev acc
    else if pos = len || Char.equal (String.unsafe_get s pos) ',' then
      let item_stop =
        match comment_char with
        | None -> pos
        | Some comment -> (
            match find_char_between s item_start pos comment with
            | -1 -> pos
            | comment_pos -> comment_pos)
      in
      let acc =
        match find_char_between s item_start item_stop '=' with
        | -1 -> acc
        | eq when has_char_between s (eq + 1) item_stop '=' -> acc
        | eq ->
            let key = trimmed_sub s item_start eq in
            if String.equal key "" then acc
            else
              let value = trimmed_sub s (eq + 1) item_stop in
              if (not allow_empty_value) && String.equal value "" then acc
              else (key, value) :: acc
      in
      loop (pos + 1) acc (pos + 1)
    else loop item_start acc (pos + 1)
  in
  if String_helpers.is_blank s then [] else loop 0 [] 0

let parse_trace_state s =
  parse_comma_pairs ~allow_empty_value:false s

let parse_baggage s =
  parse_comma_pairs ~comment_char:';' ~allow_empty_value:true s

let parse_traceparent s =
  let start, stop = String_helpers.trim_bounds s in
  let first = find_char_between s start stop '-' in
  if first < 0 then None
  else
    let second = find_char_between s (first + 1) stop '-' in
    if second < 0 then None
    else
      let third = find_char_between s (second + 1) stop '-' in
      if third < 0 then None
      else
        let fourth = find_char_between s (third + 1) stop '-' in
        let version = String.sub s start (first - start) in
        let trace_id = String.sub s (first + 1) (second - first - 1) in
        let span_id = String.sub s (second + 1) (third - second - 1) in
        let flags_stop = if fourth < 0 then stop else fourth in
        let flags = String.sub s (third + 1) (flags_stop - third - 1) in
        match parse_flags flags with
        | None -> None
        | Some trace_flags ->
            if String.equal version "00" then
              if fourth < 0 then Some (version, trace_id, span_id, trace_flags)
              else None
            else if valid_version version then
              Some (version, trace_id, span_id, trace_flags land 1)
            else None

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
      match parse_traceparent traceparent with
      | None -> None
      | Some (_, trace_id, span_id, trace_flags) ->
          make_from_traceparent ~trace_id ~span_id ~trace_flags)

let render_pairs xs =
  String.concat "," (List.map (fun (k, v) -> k ^ "=" ^ v) xs)

let inject t =
  let traceparent = Bytes.create 55 in
  Bytes.unsafe_set traceparent 0 '0';
  Bytes.unsafe_set traceparent 1 '0';
  Bytes.unsafe_set traceparent 2 '-';
  Bytes.blit_string t.trace_id 0 traceparent 3 32;
  Bytes.unsafe_set traceparent 35 '-';
  Bytes.blit_string t.span_id 0 traceparent 36 16;
  Bytes.unsafe_set traceparent 52 '-';
  let flags = t.trace_flags land 255 in
  Bytes.unsafe_set traceparent 53 (String_helpers.lower_hex_digit (flags lsr 4));
  Bytes.unsafe_set traceparent 54 (String_helpers.lower_hex_digit (flags land 0xf));
  let traceparent = Bytes.unsafe_to_string traceparent in
  let headers =
    match t.baggage with
    | [] -> []
    | xs -> [ ("baggage", render_pairs xs) ]
  in
  let headers =
    match t.trace_state with
    | [] -> headers
    | xs -> ("tracestate", render_pairs xs) :: headers
  in
  ("traceparent", traceparent) :: headers
