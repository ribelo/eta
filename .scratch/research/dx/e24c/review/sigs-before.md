# DX-E24c public signatures — before

The eight schedule-driven operation signatures carried a third hook parameter.
The hook was an Eta effect whose typed error matched the operation.

```ocaml
(* Eta.Effect *)
val retry :
  schedule:('err, 'schedule_out, (unit, 'err) t) Schedule.t ->
  while_:('err -> bool) -> ('a, 'err) t -> ('a, 'err) t

val retry_or_else :
  schedule:('err1, 'schedule_out, (unit, 'err2) t) Schedule.t ->
  while_:('err1 -> bool) ->
  or_else:('err1 -> 'schedule_out option -> ('a, 'err2) t) ->
  ('a, 'err1) t -> ('a, 'err2) t

val repeat :
  schedule:('a, 'output, (unit, 'err) t) Schedule.t ->
  ('a, 'err) t -> ('output, 'err) t

(* Eta.Resource *)
val auto :
  ?on_error:('err -> unit) ->
  load:('a, 'err) Effect.t ->
  ?random:Capabilities.random ->
  schedule:(unit, 'schedule_out, (unit, 'err) Effect.t) Schedule.t ->
  unit -> (('a, 'err) t, 'err) Effect.t

(* Eta_stream.Stream *)
val from_schedule :
  (unit, 'out, (unit, 'err) Eta.Effect.t) Eta.Schedule.t ->
  ('out, 'err) t

val schedule :
  ('a, 'out, (unit, 'err) Eta.Effect.t) Eta.Schedule.t ->
  ('a, 'err) t -> ('a, 'err) t

val repeat :
  (unit, 'out, (unit, 'err) Eta.Effect.t) Eta.Schedule.t ->
  ('a, 'err) t -> ('a, 'err) t

val retry :
  ('err, 'out, (unit, 'err) Eta.Effect.t) Eta.Schedule.t ->
  ('a, 'err) t -> ('a, 'err) t
```
