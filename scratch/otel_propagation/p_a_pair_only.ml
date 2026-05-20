open Services

type runtime = { mutable external_parent : (string * string) option }

let with_external_parent ~trace_id ~span_id rt f =
  let old = rt.external_parent in
  rt.external_parent <- Some (trace_id, span_id);
  Fun.protect ~finally:(fun () -> rt.external_parent <- old) f

let current_context rt =
  match rt.external_parent with
  | None -> None
  | Some (trace_id, span_id) ->
      Some { trace_id; span_id; trace_flags = 1; trace_state = []; baggage = [] }

let inject = function
  | None -> []
  | Some ctx ->
      [
        ( "traceparent",
          Printf.sprintf "00-%s-%s-%02x" ctx.trace_id ctx.span_id ctx.trace_flags );
      ]

let scenario_drops_state_and_baggage () =
  let rt = { external_parent = None } in
  with_external_parent ~trace_id:parent_sampled.trace_id
    ~span_id:parent_sampled.span_id rt @@ fun () ->
  match current_context rt with
  | None -> failwith "missing context"
  | Some ctx ->
      assert_equal "trace_id" parent_sampled.trace_id ctx.trace_id;
      assert_bool "trace_state dropped" (ctx.trace_state = []);
      assert_bool "baggage dropped" (ctx.baggage = [])

module type SIG = sig
  val scenario_drops_state_and_baggage : unit -> unit
end

module _ : SIG = struct
  let scenario_drops_state_and_baggage = scenario_drops_state_and_baggage
end

