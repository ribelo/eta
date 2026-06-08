val await_promise :
  ?name:string ->
  ?on_cancel:(unit -> unit) ->
  (unit -> 'a Js.Promise.t) ->
  ('a, 'err) Effect.t

val await_abortable :
  ?name:string ->
  (Js_interop.abort_signal -> ('a, 'err) result Js.Promise.t) ->
  ('a, 'err) Effect.t
