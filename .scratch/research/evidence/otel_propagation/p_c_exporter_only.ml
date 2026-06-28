open Services

let inject ctx =
  [
    ( "traceparent",
      Printf.sprintf "00-%s-%s-%02x" ctx.trace_id ctx.span_id ctx.trace_flags );
  ]

let extract headers =
  match List.assoc_opt "traceparent" headers with
  | None -> None
  | Some tp -> (
      match String.split_on_char '-' tp with
      | [ "00"; trace_id; span_id; flags ] ->
          Some
            {
              trace_id;
              span_id;
              trace_flags = int_of_string ("0x" ^ flags);
              trace_state = [];
              baggage = [];
            }
      | _ -> None)

let scenario_headers_without_runtime_context () =
  match extract (inject parent_sampled) with
  | None -> failwith "extract failed"
  | Some ctx ->
      assert_equal "trace_id" parent_sampled.trace_id ctx.trace_id;
      assert_bool "state absent at runtime boundary" (ctx.trace_state = []);
      assert_bool "baggage absent at runtime boundary" (ctx.baggage = [])

module type SIG = sig
  val inject : trace_context -> (string * string) list
  val extract : (string * string) list -> trace_context option
  val scenario_headers_without_runtime_context : unit -> unit
end

module _ : SIG = struct
  let inject = inject
  let extract = extract
  let scenario_headers_without_runtime_context = scenario_headers_without_runtime_context
end
