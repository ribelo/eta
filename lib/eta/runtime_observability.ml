module BR = Blocking_runtime

let active_span_key : int Eio.Fiber.key = Eio.Fiber.create_key ()
let sampled_key : bool Eio.Fiber.key = Eio.Fiber.create_key ()
let trace_context_key : Capabilities.trace_context Eio.Fiber.key =
  Eio.Fiber.create_key ()
let blocking_event_emit_key : (BR.event -> unit) Eio.Fiber.key =
  Eio.Fiber.create_key ()

type die_context = {
  span_name : string option;
  annotations : (string * string) list;
}

let die_context_key : die_context Eio.Fiber.key = Eio.Fiber.create_key ()
let empty_die_context = { span_name = None; annotations = [] }
let current_die_context () =
  Option.value (Eio.Fiber.get die_context_key) ~default:empty_die_context

let with_die_span_name name f =
  let context = current_die_context () in
  Eio.Fiber.with_binding die_context_key { context with span_name = Some name } f

let with_die_annotation key value f =
  let context = current_die_context () in
  let annotations = context.annotations @ [ (key, value) ] in
  Eio.Fiber.with_binding die_context_key { context with annotations } f

let with_die_annotations attrs f =
  let rec loop attrs k =
    match attrs with
    | [] -> k ()
    | (key, value) :: rest ->
        loop rest (fun () -> with_die_annotation key value k)
  in
  loop attrs f

let default_error_renderer _ = "<typed failure>"

let with_blocking_event_emit emit f =
  Eio.Fiber.with_binding blocking_event_emit_key emit f

let emit_current_blocking_event event =
  match Eio.Fiber.get blocking_event_emit_key with
  | None -> ()
  | Some emit -> emit event

let die_of_exn ?backtrace ~capture_backtrace exn =
  let backtrace =
    if capture_backtrace then
      match backtrace with
      | Some _ as bt -> bt
      | None -> Some (Printexc.get_raw_backtrace ())
    else None
  in
  let context = current_die_context () in
  Cause.die_with_diagnostics ?backtrace ?span_name:context.span_name
    ~annotations:context.annotations exn

let rec status_of_cause :
    type err.
    error_renderer:(err -> string) ->
    err Cause.t ->
    Capabilities.span_status =
 fun ~error_renderer -> function
  | Cause.Fail err -> Error (error_renderer err)
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
  | Cause.Suppressed { primary; finalizer } ->
      let render c =
        match status_of_cause ~error_renderer c with
        | Capabilities.Error msg -> msg
        | Capabilities.Cancelled -> "cancelled"
        | Capabilities.Ok -> "ok"
      in
      Error
        ("primary: " ^ render primary ^ " | suppressed finalizer: "
       ^ render finalizer)

let render_cause ~error_renderer cause =
  match status_of_cause ~error_renderer cause with
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
      List.map
        (fun (key, value) -> ("eta.annotation." ^ key, value))
        die.annotations
      @ with_span
  | Cause.Fail _ | Cause.Interrupt _ -> base
  | Cause.Sequential _ | Cause.Concurrent _ | Cause.Suppressed _ -> assert false

let exception_event_attrs_tree ~error_renderer cause =
  let rec collect path acc = function
    | Cause.Fail _ | Cause.Die _ | Cause.Interrupt _ as c ->
        exception_event_attrs ~error_renderer path c :: acc
    | Cause.Sequential causes ->
        causes
        |> List.mapi (fun i c -> (i, c))
        |> List.fold_left
             (fun acc (i, c) ->
               collect (path ^ ".seq." ^ string_of_int i) acc c)
             acc
    | Cause.Concurrent causes ->
        causes
        |> List.mapi (fun i c -> (i, c))
        |> List.fold_left
             (fun acc (i, c) ->
               collect (path ^ ".concurrent." ^ string_of_int i) acc c)
             acc
    | Cause.Suppressed { primary; finalizer } ->
        let acc = collect (path ^ ".primary") acc primary in
        collect (path ^ ".suppressed_finalizer") acc finalizer
  in
  List.rev (collect "cause" [] cause)

let emit_daemon_failure ~now_ms ~logging_enabled
    ~(logger : Capabilities.logger) ~tracing_enabled
    ~(tracer : Capabilities.tracer) cause =
  if not (Cause.is_interrupt_only cause) then (
    let ts_ms = now_ms () in
    let attrs =
      exception_event_attrs_tree ~error_renderer:default_error_renderer cause
      |> List.map (fun attrs -> ("eta.daemon.outcome", "failure") :: attrs)
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
        tracer#begin_span ~kind:Capabilities.Internal ~name:"eta.daemon"
          ~started_ms:ts_ms ()
      in
      List.iter
        (fun attrs -> tracer#add_event ~span_id ~name:"exception" ~ts_ms ~attrs)
        attrs;
      tracer#end_span ~span_id
        ~status:(status_of_cause ~error_renderer:default_error_renderer cause)
        ~ended_ms:(now_ms ())))

let string_of_blocking_outcome = function
  | BR.Blocking_ok -> "ok"
  | BR.Blocking_error msg -> "error:" ^ msg
  | BR.Blocking_cancelled -> "cancelled"
  | BR.Blocking_rejected -> "rejected"
  | BR.Blocking_shutdown_rejected -> "shutdown"
  | BR.Blocking_detached -> "detached"

let emit_blocking_event ~now_ms ~tracing_enabled
    ~(tracer : Capabilities.tracer) ~metrics_enabled
    ~(meter : Capabilities.meter) event =
  if tracing_enabled || metrics_enabled then
    let attrs =
      [
        ("eta.blocking.pool", event.BR.pool);
        ("eta.blocking.name", event.name);
        ("eta.blocking.outcome", string_of_blocking_outcome event.outcome);
        ("eta.blocking.queue_wait_ms", string_of_int event.queue_wait_ms);
        ("eta.blocking.run_ms", string_of_int event.run_ms);
      ]
    in
    (if tracing_enabled then
       match Eio.Fiber.get active_span_key with
       | None -> ()
       | Some span_id ->
           tracer#add_event ~span_id ~name:"eta.blocking" ~ts_ms:(now_ms ())
             ~attrs);
    if metrics_enabled then (
      meter#record ~name:"eta.blocking.queue_wait_ms"
        ~description:"Time spent admitted but waiting for a blocking worker"
        ~unit_:"ms" ~kind:Capabilities.Gauge ~attrs
        ~value:(Capabilities.Int event.queue_wait_ms) ~ts_ms:(now_ms ());
      meter#record ~name:"eta.blocking.run_ms"
        ~description:"Time spent running a blocking callback" ~unit_:"ms"
        ~kind:Capabilities.Gauge ~attrs ~value:(Capabilities.Int event.run_ms)
        ~ts_ms:(now_ms ()))
