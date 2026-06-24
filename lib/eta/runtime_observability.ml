let active_span_key : int Runtime_contract.local =
  Runtime_contract.create_local ()
let sampled_key : bool Runtime_contract.local =
  Runtime_contract.create_local ()
let trace_context_key : Capabilities.trace_context Runtime_contract.local =
  Runtime_contract.create_local ()
let log_attrs_key : (string * string) list Runtime_contract.local =
  Runtime_contract.create_local ()
let minimum_log_level_key : Capabilities.log_level Runtime_contract.local =
  Runtime_contract.create_local ()
type die_context = {
  span_name : string option;
  rev_annotations : (string * string) list;
}

let die_context_key : die_context Runtime_contract.local =
  Runtime_contract.create_local ()
let empty_die_context = { span_name = None; rev_annotations = [] }

let local_get contract key = contract.Runtime_contract.local_get key

let local_with_binding contract key value f =
  contract.Runtime_contract.local_with_binding key value f

let current_die_context contract =
  match local_get contract die_context_key with
  | Some context -> context
  | None -> empty_die_context

let current_log_attrs contract =
  match local_get contract log_attrs_key with
  | Some attrs -> attrs
  | None -> []

let with_log_attrs contract attrs f =
  match attrs with
  | [] -> f ()
  | _ ->
      let current = current_log_attrs contract in
      local_with_binding contract log_attrs_key (current @ attrs) f

let log_level_rank = function
  | Capabilities.Trace -> 0
  | Capabilities.Debug -> 1
  | Capabilities.Info -> 2
  | Capabilities.Warn -> 3
  | Capabilities.Error -> 4
  | Capabilities.Fatal -> 5

let log_level_compare left right =
  Int.compare (log_level_rank left) (log_level_rank right)

let log_level_enabled ~minimum level = log_level_compare level minimum >= 0

let current_minimum_log_level contract =
  local_get contract minimum_log_level_key

let with_minimum_log_level contract level f =
  let effective =
    match current_minimum_log_level contract with
    | None -> level
    | Some current ->
        if log_level_compare current level >= 0 then current else level
  in
  local_with_binding contract minimum_log_level_key effective f

let with_die_context contract context f =
  local_with_binding contract die_context_key context f

let with_die_span_name contract name f =
  let context = current_die_context contract in
  with_die_context contract { context with span_name = Some name } f

let with_die_annotation contract key value f =
  let context = current_die_context contract in
  with_die_context contract
    { context with rev_annotations = (key, value) :: context.rev_annotations }
    f

let with_die_annotations contract attrs f =
  match attrs with
  | [] -> f ()
  | _ ->
      let context = current_die_context contract in
      with_die_context contract
        { context with rev_annotations = List.rev_append attrs context.rev_annotations }
        f

let default_error_renderer _ = "<typed failure>"
let error_renderer_raised = "<error renderer raised>"

let render_typed_failure ~error_renderer err =
  (* Error renderers are user callbacks on the diagnostic path. If one
     raises, preserve the original cause and close observability spans with a
     stable fallback instead of reporting the renderer failure as the program
     failure. *)
  try error_renderer err with _ -> error_renderer_raised

let die_of_exn contract ?backtrace ~capture_backtrace exn =
  let backtrace =
    if capture_backtrace then
      match backtrace with
      | Some _ as bt -> bt
      | None -> Some (Printexc.get_raw_backtrace ())
    else None
  in
  let context = current_die_context contract in
  Cause.die_with_diagnostics ?backtrace ?span_name:context.span_name
    ~annotations:(List.rev context.rev_annotations) exn

let rec status_of_finalizer_cause : Cause.Finalizer.t -> Capabilities.span_status =
 function
  | Cause.Finalizer.Fail msg -> Error msg
  | Cause.Finalizer.Die die -> Error (Printexc.to_string die.exn)
  | Cause.Finalizer.Interrupt _ -> Cancelled
  | Cause.Finalizer.Sequential causes | Cause.Finalizer.Concurrent causes ->
      if List.for_all Cause.Finalizer.is_interrupt_only causes then Cancelled
      else
        let render c =
          match status_of_finalizer_cause c with
          | Capabilities.Error msg -> msg
          | Capabilities.Cancelled -> "cancelled"
          | Capabilities.Ok -> "ok"
        in
        Error (String.concat " | " (List.map render causes))
  | Cause.Finalizer.Finalizer cause -> (
      match status_of_finalizer_cause cause with
      | Capabilities.Error msg -> Error ("finalizer: " ^ msg)
      | Capabilities.Cancelled -> Cancelled
      | Capabilities.Ok -> Ok)
  | Cause.Finalizer.Suppressed { primary; finalizer } ->
      let render c =
        match status_of_finalizer_cause c with
        | Capabilities.Error msg -> msg
        | Capabilities.Cancelled -> "cancelled"
        | Capabilities.Ok -> "ok"
      in
      Error
        ("primary: " ^ render primary ^ " | suppressed finalizer: "
       ^ render finalizer)

let rec status_of_cause :
    type err.
    error_renderer:(err -> string) ->
    err Cause.t ->
    Capabilities.span_status =
 fun ~error_renderer -> function
  | Cause.Fail err -> Error (render_typed_failure ~error_renderer err)
  | Cause.Die die -> Error (Printexc.to_string die.exn)
  | Cause.Interrupt _ -> Cancelled
  | Cause.Sequential causes | Cause.Concurrent causes ->
      if List.for_all Cause.is_interrupt_only causes then Cancelled
      else
        let render c =
          match status_of_cause ~error_renderer c with
          | Capabilities.Error msg -> msg
          | Capabilities.Cancelled -> "cancelled"
          | Capabilities.Ok -> "ok"
        in
        Error (String.concat " | " (List.map render causes))
  | Cause.Finalizer cause -> (
      match status_of_finalizer_cause cause with
      | Capabilities.Error msg -> Error ("finalizer: " ^ msg)
      | Capabilities.Cancelled -> Cancelled
      | Capabilities.Ok -> Ok)
  | Cause.Suppressed { primary; finalizer } ->
      let render_primary c =
        match status_of_cause ~error_renderer c with
        | Capabilities.Error msg -> msg
        | Capabilities.Cancelled -> "cancelled"
        | Capabilities.Ok -> "ok"
      in
      let render_finalizer c =
        match status_of_finalizer_cause c with
          | Capabilities.Error msg -> msg
          | Capabilities.Cancelled -> "cancelled"
          | Capabilities.Ok -> "ok"
      in
      Error
        ("primary: " ^ render_primary primary ^ " | suppressed finalizer: "
       ^ render_finalizer finalizer)

let render_cause ~error_renderer cause =
  match status_of_cause ~error_renderer cause with
  | Capabilities.Error msg -> msg
  | Capabilities.Cancelled -> "cancelled"
  | Capabilities.Ok -> "ok"

let render_finalizer_cause cause =
  match status_of_finalizer_cause cause with
  | Capabilities.Error msg -> msg
  | Capabilities.Cancelled -> "cancelled"
  | Capabilities.Ok -> "ok"

let exception_event_attrs ~error_renderer path cause =
  let base =
    [
      ("exception.message", render_cause ~error_renderer cause);
      ("eta.cause.path", path);
    ]
  in
  match cause with
  | Cause.Die die ->
      let with_type = ("exception.type", Printexc.to_string die.exn) :: base in
      let with_stack =
        match die.backtrace with
        | None -> with_type
        | Some bt ->
            ("exception.stacktrace", Printexc.raw_backtrace_to_string bt)
            :: with_type
      in
      let with_span =
        match die.span_name with
        | None -> with_stack
        | Some name -> ("eta.die.span_name", name) :: with_stack
      in
      List.rev_append
        (List.rev_map
           (fun (key, value) -> ("eta.annotation." ^ key, value))
           die.annotations)
        with_span
  | Cause.Fail _ | Cause.Interrupt _ -> base
  | Cause.Sequential _ | Cause.Concurrent _ | Cause.Finalizer _
  | Cause.Suppressed _ ->
      assert false

let exception_event_attrs_finalizer path cause =
  let base =
    [
      ("exception.message", render_finalizer_cause cause);
      ("eta.cause.path", path);
    ]
  in
  match cause with
  | Cause.Finalizer.Die die ->
      let with_type = ("exception.type", Printexc.to_string die.exn) :: base in
      let with_stack =
        match die.backtrace with
        | None -> with_type
        | Some bt ->
            ("exception.stacktrace", Printexc.raw_backtrace_to_string bt)
            :: with_type
      in
      let with_span =
        match die.span_name with
        | None -> with_stack
        | Some name -> ("eta.die.span_name", name) :: with_stack
      in
      List.rev_append
        (List.rev_map
           (fun (key, value) -> ("eta.annotation." ^ key, value))
           die.annotations)
        with_span
  | Cause.Finalizer.Fail _ | Cause.Finalizer.Interrupt _ -> base
  | Cause.Finalizer.Sequential _ | Cause.Finalizer.Concurrent _
  | Cause.Finalizer.Finalizer _ | Cause.Finalizer.Suppressed _ ->
      assert false

let exception_event_attrs_tree ~error_renderer cause =
  let rec fold_indexed f path index acc = function
    | [] -> acc
    | cause :: rest ->
        let acc = f (path ^ string_of_int index) acc cause in
        fold_indexed f path (index + 1) acc rest
  in
  let rec collect path acc = function
    | Cause.Fail _ | Cause.Die _ | Cause.Interrupt _ as c ->
        exception_event_attrs ~error_renderer path c :: acc
    | Cause.Sequential causes ->
        fold_indexed collect (path ^ ".seq.") 0 acc causes
    | Cause.Concurrent causes ->
        fold_indexed collect (path ^ ".concurrent.") 0 acc causes
    | Cause.Finalizer cause -> collect_finalizer (path ^ ".finalizer") acc cause
    | Cause.Suppressed { primary; finalizer } ->
        let acc = collect (path ^ ".primary") acc primary in
        collect_finalizer (path ^ ".suppressed_finalizer") acc finalizer
  and collect_finalizer path acc = function
    | Cause.Finalizer.Fail _ | Cause.Finalizer.Die _ | Cause.Finalizer.Interrupt _
      as c ->
        exception_event_attrs_finalizer path c :: acc
    | Cause.Finalizer.Sequential causes ->
        fold_indexed collect_finalizer (path ^ ".seq.") 0 acc causes
    | Cause.Finalizer.Concurrent causes ->
        fold_indexed collect_finalizer (path ^ ".concurrent.") 0 acc causes
    | Cause.Finalizer.Finalizer cause ->
        collect_finalizer (path ^ ".finalizer") acc cause
    | Cause.Finalizer.Suppressed { primary; finalizer } ->
        let acc = collect_finalizer (path ^ ".primary") acc primary in
        collect_finalizer (path ^ ".suppressed_finalizer") acc finalizer
  in
  List.rev (collect "cause" [] cause)

let emit_daemon_failure ~contract ~now_ms ~logging_enabled
    ~(logger : Capabilities.logger) ~tracing_enabled
    ~(tracer : Capabilities.tracer) cause =
  if not (Cause.is_interrupt_only cause) then (
    let ts_ms = now_ms () in
    let rec with_failure_outcome acc = function
      | [] -> List.rev acc
      | attrs :: rest ->
          with_failure_outcome
            ((("eta.daemon.outcome", "failure") :: attrs) :: acc)
            rest
    in
    let attrs =
      exception_event_attrs_tree ~error_renderer:default_error_renderer cause
      |> with_failure_outcome []
    in
    if logging_enabled then
      List.iter
        (fun attrs ->
          logger#log
            {
              Capabilities.level = Error;
              body = "eta.daemon.failure";
              ts_ms;
              attrs;
              trace_id = "";
              span_id = "";
            })
        attrs;
    if tracing_enabled then (
      let span_id =
        tracer#begin_span contract ~kind:Capabilities.Internal ~name:"eta.daemon"
          ~started_ms:ts_ms ()
      in
      List.iter
        (fun attrs ->
          tracer#add_event contract ~span_id ~name:"exception" ~ts_ms ~attrs)
        attrs;
      tracer#end_span contract ~span_id
        ~status:(status_of_cause ~error_renderer:default_error_renderer cause)
        ~ended_ms:(now_ms ())))
