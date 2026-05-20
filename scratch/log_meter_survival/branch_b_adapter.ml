open Common

type runtime_observation = {
  sink : sink;
  active_span : span option;
}

let observation_key : runtime_observation Eio.Fiber.key = Eio.Fiber.create_key ()

let current_observation () =
  try Eio.Fiber.get observation_key with Stdlib.Effect.Unhandled _ -> None

let log_level_of_logs = function
  | Logs.App -> Info
  | Logs.Error -> Error
  | Logs.Warning -> Warn
  | Logs.Info -> Info
  | Logs.Debug -> Debug

let emit_log ?(level = Info) ?(attrs = []) body =
  match current_observation () with
  | None -> ()
  | Some { sink; active_span } ->
      let trace_id, span_id =
        match active_span with
        | None -> ("", "")
        | Some span -> (span.trace_id, span.span_id)
      in
      add_log sink { level; body; attrs; trace_id; span_id }

let reporter () =
  let report _src level ~over k msgf =
    msgf @@ fun ?header:_ ?tags:_ fmt ->
    Format.kasprintf
      (fun body ->
        emit_log ~level:(log_level_of_logs level) body;
        over ();
        k ())
      fmt
  in
  { Logs.report }

module Metric_registry = struct
  let record ?(attrs = []) ~name ~kind value =
    match current_observation () with
    | None -> ()
    | Some { sink; active_span } ->
        let trace_id, span_id =
          match active_span with
          | None -> ("", "")
          | Some span -> (span.trace_id, span.span_id)
        in
        add_metric sink { name; kind; attrs; value; trace_id; span_id }
end

type _ eff =
  | Pure : 'a -> 'a eff
  | Sync : string * (unit -> 'a) -> 'a eff
  | Bind : 'a eff * ('a -> 'b eff) -> 'b eff
  | Named : string * 'a eff -> 'a eff

let pure value = Pure value
let sync name f = Sync (name, f)
let bind eff f = Bind (eff, f)
let named name eff = Named (name, eff)
let ( let* ) eff f = bind eff f

let log ?(level = Logs.Info) ?(attrs = []) body =
  sync "Logs.emit" (fun () ->
      Logs.msg level (fun m -> m "%s" body);
      match attrs with
      | [] -> ()
      | _ -> emit_log ~level:(log_level_of_logs level) ~attrs body)

let metric_update ?(attrs = []) ~name ~kind value =
  sync "Metric_registry.record" (fun () ->
      Metric_registry.record ~attrs ~name ~kind value)

let rec run_effect : type a. sink -> span option -> a eff -> a =
 fun sink active -> function
  | Pure value -> value
  | Sync (_, f) ->
      Eio.Fiber.with_binding observation_key { sink; active_span = active } f
  | Bind (eff, f) ->
      let value = run_effect sink active eff in
      run_effect sink active (f value)
  | Named (name, eff) ->
      let span = begin_span sink name in
      Eio.Fiber.with_binding observation_key
        { sink; active_span = Some span }
        (fun () -> run_effect sink (Some span) eff)

let with_reporter f =
  let old_reporter = Logs.reporter () in
  let old_level = Logs.level () in
  Logs.set_reporter (reporter ());
  Logs.set_level (Some Logs.Debug);
  Fun.protect f ~finally:(fun () ->
      Logs.set_reporter old_reporter;
      Logs.set_level old_level)

let run sink eff = with_reporter (fun () -> run_effect sink None eff)

let fixture () =
  let sink = create_sink () in
  let program =
    named "parent"
      (let* () = log "hello" in
       metric_update ~name:"requests" ~kind:Counter (Int 1))
  in
  run sink program;
  sink

module type SIG = sig
  val program : unit eff
  val run_program : sink -> unit
end

module _ : SIG = struct
  let program =
    named "parent"
      (let* () = log "hello" in
       metric_update ~name:"requests" ~kind:Counter (Int 1))

  let run_program sink = run sink program
end
