open Common

type _ eff =
  | Pure : 'a -> 'a eff
  | Sync : string * (unit -> 'a) -> 'a eff
  | Bind : 'a eff * ('a -> 'b eff) -> 'b eff
  | Named : string * 'a eff -> 'a eff
  | Log : log_level * string * (string * string) list -> unit eff
  | Metric_update :
      string * metric_kind * metric_value * (string * string) list
      -> unit eff

let pure value = Pure value
let sync name f = Sync (name, f)
let bind eff f = Bind (eff, f)
let named name eff = Named (name, eff)
let log ?(level = Info) ?(attrs = []) body = Log (level, body, attrs)
let metric_update ?(attrs = []) ~name ~kind value =
  Metric_update (name, kind, value, attrs)

let ( let* ) eff f = bind eff f

let rec run : type a. sink -> span option -> a eff -> a =
 fun sink active -> function
  | Pure value -> value
  | Sync (_, f) -> f ()
  | Bind (eff, f) ->
      let value = run sink active eff in
      run sink active (f value)
  | Named (name, eff) ->
      let span = begin_span sink name in
      run sink (Some span) eff
  | Log (level, body, attrs) ->
      let trace_id, span_id =
        match active with
        | None -> ("", "")
        | Some span -> (span.trace_id, span.span_id)
      in
      add_log sink { level; body; attrs; trace_id; span_id }
  | Metric_update (name, kind, value, attrs) ->
      let trace_id, span_id =
        match active with
        | None -> ("", "")
        | Some span -> (span.trace_id, span.span_id)
      in
      add_metric sink { name; kind; attrs; value; trace_id; span_id }

let run sink eff = run sink None eff

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
