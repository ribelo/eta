open Runtime_core

let add_random_hex16 buffer random =
  let value = int_of_float (Capabilities.random_float random 65_536.0) in
  Buffer.add_char buffer (String_helpers.lower_hex_digit ((value lsr 12) land 0xf));
  Buffer.add_char buffer (String_helpers.lower_hex_digit ((value lsr 8) land 0xf));
  Buffer.add_char buffer (String_helpers.lower_hex_digit ((value lsr 4) land 0xf));
  Buffer.add_char buffer (String_helpers.lower_hex_digit (value land 0xf))

let random_trace_id runtime =
  let rec loop () =
    let buffer = Buffer.create 32 in
    for _ = 1 to 8 do
      add_random_hex16 buffer runtime.random
    done;
    let trace_id = Buffer.contents buffer in
    if String.exists (( <> ) '0') trace_id then trace_id else loop ()
  in
  loop ()

let with_span ~runtime ~error_renderer ~fail_key ~kind ~name ~attrs body =
  let contract = runtime.contract in
  let local_get key = contract.Runtime_contract.local_get key in
  let local_with_binding key value f =
    contract.Runtime_contract.local_with_binding key value f
  in
  let with_die_context f =
    RObs.with_die_span_name contract name @@ fun () ->
    RObs.with_die_annotations contract attrs f
  in
  let run_body () =
    try body () with exn ->
      raise_cause fail_key (cause_of_exn_runtime runtime fail_key exn)
  in
  if not runtime.tracing_enabled then with_die_context run_body
  else
    let parent_id = local_get RObs.active_span_key in
    let ambient_context = local_get RObs.trace_context_key in
    let parent_sampled =
      Option.value (local_get RObs.sampled_key)
        ~default:
          (match ambient_context with
          | None -> true
          | Some ctx -> Trace_context.sampled ctx)
    in
    let external_parent =
      match parent_id with
      | Some _ -> None
      | None -> ambient_context
    in
    let trace_id, root_trace_id =
      match (parent_id, ambient_context) with
      | Some span_id, _ -> (
          match runtime.tracer#inspect contract ~span_id with
          | Some info -> (info.trace_id, None)
          | None ->
              let trace_id = random_trace_id runtime in
              (trace_id, None))
      | None, Some ctx -> (ctx.trace_id, None)
      | None, None ->
          let trace_id = random_trace_id runtime in
          (trace_id, Some trace_id)
    in
    let sampled =
      parent_sampled
      && Sampler.sample runtime.sampler ~trace_id ~name ~attrs:[]
           ~parent:(Option.is_some parent_id || Option.is_some ambient_context)
    in
    if not sampled then
      with_die_context @@ fun () ->
      local_with_binding RObs.sampled_key false run_body
    else
      let started_ms = runtime.now_ms () in
      let span_id =
        runtime.tracer#begin_span contract ?parent_id ?external_parent
          ?trace_id:root_trace_id ~name ~kind ~started_ms ()
      in
      let finish status =
        runtime.tracer#end_span contract ~span_id ~status
          ~ended_ms:(runtime.now_ms ())
      in
      let emit_exception_event cause =
        RObs.exception_event_attrs_tree ~error_renderer cause
        |> List.iter (fun attrs ->
               runtime.tracer#add_event contract ~span_id ~name:"exception"
                 ~ts_ms:(runtime.now_ms ()) ~attrs)
      in
      with_die_context @@ fun () ->
      local_with_binding RObs.active_span_key span_id @@ fun () ->
      local_with_binding RObs.sampled_key true @@ fun () ->
      try
        List.iter
          (fun (key, value) ->
            runtime.tracer#add_attr_to contract ~span_id ~key ~value)
          attrs;
        let value = body () in
        finish Ok;
        value
      with exn ->
        let cause = cause_of_exn_runtime runtime fail_key exn in
        (* error_pp must be total. A raising printer becomes a defect via the
           ordinary capture path; still close the span so telemetry degrades
           honestly instead of leaking an open span. *)
        (match
           try
             emit_exception_event cause;
             finish (RObs.status_of_cause ~error_renderer cause);
             None
           with render_exn ->
             let render_cause =
               cause_of_exn_runtime runtime fail_key render_exn
             in
             (try finish (RObs.status_of_cause ~error_renderer:RObs.default_error_renderer render_cause)
              with _ -> finish (Error "<error_pp raised>"));
             Some render_cause
         with
         | None -> raise_cause fail_key cause
         | Some render_cause -> raise_cause fail_key render_cause)

let instrument_leaf ~runtime ~error_renderer ~fail_key ~name f =
  with_span ~runtime ~error_renderer ~fail_key ~kind:Capabilities.Internal ~name
    ~attrs:[] f
