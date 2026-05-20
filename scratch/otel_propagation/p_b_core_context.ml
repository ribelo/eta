open Services

type runtime = { mutable context : trace_context option }

let is_hex len s =
  String.length s = len
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       s

let not_zero s = String.exists (( <> ) '0') s

let parse_hex2 s =
  if not (is_hex 2 s) then None else Some (int_of_string ("0x" ^ s))

let trim = String.trim

let parse_pairs s =
  if trim s = "" then []
  else
    s |> String.split_on_char ','
    |> List.filter_map (fun item ->
           match String.split_on_char '=' item with
           | [ k; v ] -> Some (trim k, trim v)
           | _ -> None)

let parse_baggage s =
  if trim s = "" then []
  else
    s |> String.split_on_char ','
    |> List.filter_map (fun item ->
           let item =
             match String.split_on_char ';' item with
             | head :: _ -> head
             | [] -> item
           in
           match String.split_on_char '=' item with
           | [ k; v ] -> Some (trim k, trim v)
           | _ -> None)

let find_header name headers =
  List.find_map
    (fun (k, v) -> if String.lowercase_ascii k = name then Some v else None)
    headers

let extract headers =
  match find_header "traceparent" headers with
  | None -> None
  | Some value -> (
      match String.split_on_char '-' value with
      | [ "00"; trace_id; span_id; flags ] ->
          if is_hex 32 trace_id && not_zero trace_id && is_hex 16 span_id
             && not_zero span_id
          then
            Option.map
              (fun trace_flags ->
                {
                  trace_id;
                  span_id;
                  trace_flags;
                  trace_state =
                    Option.value
                      (Option.map parse_pairs (find_header "tracestate" headers))
                      ~default:[];
                  baggage =
                    Option.value
                      (Option.map parse_baggage (find_header "baggage" headers))
                      ~default:[];
                })
              (parse_hex2 flags)
          else None
      | _ -> None)

let inject ctx =
  let base =
    [
      ( "traceparent",
        Printf.sprintf "00-%s-%s-%02x" ctx.trace_id ctx.span_id
          (ctx.trace_flags land 255) );
    ]
  in
  let trace_state =
    match ctx.trace_state with
    | [] -> []
    | xs ->
        [
          ( "tracestate",
            String.concat "," (List.map (fun (k, v) -> k ^ "=" ^ v) xs) );
        ]
  in
  let baggage =
    match ctx.baggage with
    | [] -> []
    | xs ->
        [ ("baggage", String.concat "," (List.map (fun (k, v) -> k ^ "=" ^ v) xs)) ]
  in
  base @ trace_state @ baggage

let with_context ctx rt f =
  let old = rt.context in
  rt.context <- Some ctx;
  Fun.protect ~finally:(fun () -> rt.context <- old) f

let current_context rt = rt.context

let parent_allows_sample rt name =
  match rt.context with
  | Some ctx when ctx.trace_flags land 1 = 0 -> false
  | _ -> name <> ""

let named rt name f = if parent_allows_sample rt name then f () else ()

let scenario_full_round_trip () =
  let headers = inject parent_sampled in
  match extract headers with
  | None -> failwith "extract failed"
  | Some ctx ->
      assert_equal "trace_id" parent_sampled.trace_id ctx.trace_id;
      assert_equal "trace_state" "00f067aa0ba902b7"
        (List.assoc "rojo" ctx.trace_state);
      assert_equal "baggage" "acme" (List.assoc "tenant" ctx.baggage)

let scenario_unsampled_suppresses_child () =
  let rt = { context = None } in
  let ran = ref false in
  with_context parent_unsampled rt @@ fun () ->
  named rt "child" (fun () -> ran := true);
  assert_bool "unsampled parent suppressed child" (not !ran)

module type SIG = sig
  val extract : (string * string) list -> trace_context option
  val inject : trace_context -> (string * string) list
  val with_context : trace_context -> runtime -> (unit -> 'a) -> 'a
  val current_context : runtime -> trace_context option
  val scenario_full_round_trip : unit -> unit
  val scenario_unsampled_suppresses_child : unit -> unit
end

module _ : SIG = struct
  let extract = extract
  let inject = inject
  let with_context = with_context
  let current_context = current_context
  let scenario_full_round_trip = scenario_full_round_trip
  let scenario_unsampled_suppresses_child = scenario_unsampled_suppresses_child
end
