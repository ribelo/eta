# DX-E24c public signatures — after

All eight operations accept the same two-parameter schedule description. There
is no hook/error channel hidden in `Schedule.t`.

```ocaml
(* Eta.Effect *)
val retry :
  schedule:('err, 'schedule_out) Schedule.t ->
  while_:('err -> bool) -> ('a, 'err) t -> ('a, 'err) t

val retry_or_else :
  schedule:('err1, 'schedule_out) Schedule.t ->
  while_:('err1 -> bool) ->
  or_else:('err1 -> 'schedule_out option -> ('a, 'err2) t) ->
  ('a, 'err1) t -> ('a, 'err2) t

val repeat :
  schedule:('a, 'output) Schedule.t ->
  ('a, 'err) t -> ('output, 'err) t

(* Eta.Resource *)
val auto :
  ?on_error:('err -> unit) ->
  load:('a, 'err) Effect.t ->
  ?random:Capabilities.random ->
  schedule:(unit, 'schedule_out) Schedule.t ->
  unit -> (('a, 'err) t, 'err) Effect.t

(* Eta_stream.Stream *)
val from_schedule :
  (unit, 'out) Eta.Schedule.t -> ('out, 'err) t

val schedule :
  ('a, 'out) Eta.Schedule.t -> ('a, 'err) t -> ('a, 'err) t

val repeat :
  (unit, 'out) Eta.Schedule.t -> ('a, 'err) t -> ('a, 'err) t

val retry :
  ('err, 'out) Eta.Schedule.t -> ('a, 'err) t -> ('a, 'err) t
```

The two HTTP retry entry points likewise use
`(unit, 'schedule_out) Eta.Schedule.t`; `Schedule.no_hook` no longer exists.
